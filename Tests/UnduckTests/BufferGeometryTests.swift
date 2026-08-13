import Testing
import Foundation
import CoreAudio
import CUnduckRender
@testable import Unduck

/// A heap-allocated AudioBufferList shaped like a real device's, so the geometry
/// code is exercised against the layouts that actually ship: the built-in
/// speakers (2ch interleaved), a Studio Display (8ch interleaved), a planar
/// device (one buffer per channel) and a mono sink.
final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []

    /// - Parameter channelsPerBuffer: e.g. `[8]` for one 8-channel interleaved
    ///   buffer, `[1, 1]` for a planar stereo pair.
    init(channelsPerBuffer: [Int], frames: Int, fill: Float = 0) {
        list = AudioBufferList.allocate(maximumBuffers: channelsPerBuffer.count)
        for (i, channels) in channelsPerBuffer.enumerated() {
            let count = max(channels * frames, 1)
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            buffer.initialize(repeating: fill, count: count)
            storage.append(buffer)
            list[i] = AudioBuffer(mNumberChannels: UInt32(channels),
                                  mDataByteSize: UInt32(channels * frames * MemoryLayout<Float>.size),
                                  mData: UnsafeMutableRawPointer(buffer))
        }
    }

    deinit {
        for buffer in storage { buffer.deallocate() }
        free(list.unsafeMutablePointer)
    }

    /// Sample of `channel` at `frame`, resolved through the list's own geometry.
    func sample(channel: Int, frame: Int) -> Float {
        let ref = locateChannel(list, channel)
        guard let base = ref.base else { return .nan }
        return base[frame * ref.stride]
    }
}

private func isClose(_ a: Float, _ b: Float, _ tolerance: Float = 1e-6) -> Bool {
    abs(a - b) <= tolerance
}

// MARK: - locating a channel

@Suite("Buffer-list geometry")
struct BufferGeometryTests {

    @Test("An interleaved stereo buffer (built-in speakers) strides by its channel count")
    func interleavedStereo() {
        let list = TestBufferList(channelsPerBuffer: [2], frames: 64)
        let left = locateChannel(list.list, 0)
        let right = locateChannel(list.list, 1)

        #expect(left.stride == 2)
        #expect(right.stride == 2)
        // The old code read frames as mDataByteSize / sizeof(Float), i.e. 128 here.
        #expect(left.frames == 64)
        #expect(right.frames == 64)
        #expect(right.base! - left.base! == 1)
    }

    @Test("An 8-channel interleaved buffer (Studio Display) resolves every channel")
    func interleavedEightChannel() {
        let list = TestBufferList(channelsPerBuffer: [8], frames: 32)
        let left = locateChannel(list.list, 0)
        let right = locateChannel(list.list, 1)

        #expect(left.stride == 8)
        // The old bytes/sizeof(Float) reading would have claimed 256 frames here,
        // which is exactly how a block of media got smeared over four output blocks.
        #expect(left.frames == 32)
        #expect(right.base! - left.base! == 1)

        let last = locateChannel(list.list, 7)
        #expect(last.base! - left.base! == 7)
        #expect(last.frames == 32)
    }

    @Test("A planar list (one buffer per channel) strides by one")
    func planarLayout() {
        let list = TestBufferList(channelsPerBuffer: [1, 1], frames: 16)
        let left = locateChannel(list.list, 0)
        let right = locateChannel(list.list, 1)

        #expect(left.stride == 1)
        #expect(right.stride == 1)
        #expect(left.frames == 16)
        #expect(left.base != right.base)
    }

    @Test("Channels are counted across buffers, not per buffer")
    func channelsSpanBuffers() {
        // A mixed list: a stereo interleaved buffer followed by two mono buffers.
        let list = TestBufferList(channelsPerBuffer: [2, 1, 1], frames: 8)
        #expect(locateChannel(list.list, 0).stride == 2)
        #expect(locateChannel(list.list, 1).stride == 2)
        #expect(locateChannel(list.list, 2).stride == 1)   // second buffer
        #expect(locateChannel(list.list, 3).stride == 1)
        #expect(locateChannel(list.list, 4).base == nil)   // past the end
    }

    @Test("Out-of-range and negative channels resolve to nothing, not a stray pointer")
    func outOfRange() {
        let list = TestBufferList(channelsPerBuffer: [2], frames: 8)
        #expect(locateChannel(list.list, 2).base == nil)
        #expect(locateChannel(list.list, -1).base == nil)
    }

    @Test("A mono device has a left channel and no right")
    func monoDevice() {
        let list = TestBufferList(channelsPerBuffer: [1], frames: 8)
        let only = locateChannel(list.list, 0)
        #expect(only.stride == 1)
        #expect(only.frames == 8)
        #expect(locateChannel(list.list, 1).base == nil)
    }

    @Test("Silencing clears every buffer in the list")
    func silenceClearsEverything() {
        let list = TestBufferList(channelsPerBuffer: [8], frames: 4, fill: 0.7)
        silenceBuffers(list.list)
        for channel in 0..<8 {
            for frame in 0..<4 {
                #expect(list.sample(channel: channel, frame: frame) == 0)
            }
        }
    }
}

// MARK: - end to end through the render core

@Suite("Rendering into real device layouts")
struct RenderGeometryTests {

    /// Render a known stereo ramp from a tap-shaped buffer list into a device
    /// shaped like `outChannelsPerBuffer`, at unity gain with the limiter parked
    /// open - so the output must be the input placed verbatim in the stereo pair.
    private func render(inChannelsPerBuffer: [Int],
                        outChannelsPerBuffer: [Int],
                        frames: Int,
                        left: Int = 0,
                        right: Int = 1,
                        outFill: Float = 0) -> (input: TestBufferList, output: TestBufferList) {
        let input = TestBufferList(channelsPerBuffer: inChannelsPerBuffer, frames: frames)
        let output = TestBufferList(channelsPerBuffer: outChannelsPerBuffer, frames: frames, fill: outFill)

        // Distinguishable, non-symmetric content: L ramps up, R ramps down.
        let inL = locateChannel(input.list, 0)
        let inR = locateChannel(input.list, 1)
        for frame in 0..<frames {
            inL.base![frame * inL.stride] = Float(frame) / Float(frames)
            if let base = inR.base { base[frame * inR.stride] = -Float(frame) / Float(frames) }
        }

        let state = UnsafeMutablePointer<UnduckRenderState>.allocate(capacity: 1)
        defer { state.deallocate() }
        unduck_init(state, 48_000, 1.0, 8.0)   // unity gain, ceiling far above the signal

        silenceBuffers(output.list)
        let outL = locateChannel(output.list, left)
        let outR = left == right ? ChannelRef() : locateChannel(output.list, right)
        unduck_render(state,
                      UnduckSrc(base: UnsafePointer(inL.base), stride: Int32(inL.stride)),
                      UnduckSrc(base: UnsafePointer(inR.base), stride: Int32(inR.stride)),
                      Int32(inL.frames),
                      UnduckDst(base: outL.base, stride: Int32(outL.stride)),
                      UnduckDst(base: outR.base, stride: Int32(outR.stride)),
                      Int32(outR.base == nil ? outL.frames : min(outL.frames, outR.frames)))
        return (input, output)
    }

    @Test("Built-in speakers: the layout that already worked keeps working")
    func builtInSpeakers() {
        let frames = 64
        let (input, output) = render(inChannelsPerBuffer: [2], outChannelsPerBuffer: [2], frames: frames)
        for frame in 0..<frames {
            #expect(isClose(output.sample(channel: 0, frame: frame), input.sample(channel: 0, frame: frame)))
            #expect(isClose(output.sample(channel: 1, frame: frame), input.sample(channel: 1, frame: frame)))
        }
    }

    @Test("Studio Display: media lands in the stereo pair at full rate, the rest stays silent")
    func eightChannelDisplay() {
        // The regression this change is about: a 2ch tap into an 8ch interleaved
        // device. Every frame must line up 1:1 (not stretched by four), and the six
        // unused speaker channels must be silent rather than stale.
        let frames = 64
        let (input, output) = render(inChannelsPerBuffer: [2], outChannelsPerBuffer: [8], frames: frames,
                                     outFill: 0.9)   // stale contents, as Core Audio really hands them over
        for frame in 0..<frames {
            #expect(isClose(output.sample(channel: 0, frame: frame), input.sample(channel: 0, frame: frame)))
            #expect(isClose(output.sample(channel: 1, frame: frame), input.sample(channel: 1, frame: frame)))
            for channel in 2..<8 {
                #expect(output.sample(channel: channel, frame: frame) == 0)
            }
        }
    }

    @Test("A planar sink gets the channels split across its buffers")
    func planarSink() {
        let frames = 32
        let (input, output) = render(inChannelsPerBuffer: [2], outChannelsPerBuffer: [1, 1], frames: frames)
        for frame in 0..<frames {
            #expect(isClose(output.sample(channel: 0, frame: frame), input.sample(channel: 0, frame: frame)))
            #expect(isClose(output.sample(channel: 1, frame: frame), input.sample(channel: 1, frame: frame)))
        }
    }

    @Test("A planar source into an interleaved sink (the reverse mismatch)")
    func planarSourceInterleavedSink() {
        let frames = 32
        let (input, output) = render(inChannelsPerBuffer: [1, 1], outChannelsPerBuffer: [2], frames: frames)
        for frame in 0..<frames {
            #expect(isClose(output.sample(channel: 0, frame: frame), input.sample(channel: 0, frame: frame)))
            #expect(isClose(output.sample(channel: 1, frame: frame), input.sample(channel: 1, frame: frame)))
        }
    }

    @Test("A mono sink gets the downmix, not one side dropped")
    func monoSink() {
        // Bluetooth headset mode: one channel out. L ramps up and R ramps down by
        // the same amount, so a correct downmix is silence.
        let frames = 16
        let (_, output) = render(inChannelsPerBuffer: [2], outChannelsPerBuffer: [1], frames: frames,
                                 left: 0, right: 0)
        for frame in 0..<frames {
            #expect(isClose(output.sample(channel: 0, frame: frame), 0))
        }
    }

    @Test("A short tap block silences the remainder instead of leaving stale audio")
    func shortTapBlock() {
        let frames = 32
        let input = TestBufferList(channelsPerBuffer: [2], frames: frames / 2)
        let output = TestBufferList(channelsPerBuffer: [8], frames: frames, fill: 0.9)
        let inL = locateChannel(input.list, 0)
        let inR = locateChannel(input.list, 1)
        for frame in 0..<(frames / 2) {
            inL.base![frame * inL.stride] = 0.5
            inR.base![frame * inR.stride] = 0.5
        }

        let state = UnsafeMutablePointer<UnduckRenderState>.allocate(capacity: 1)
        defer { state.deallocate() }
        unduck_init(state, 48_000, 1.0, 8.0)

        silenceBuffers(output.list)
        let outL = locateChannel(output.list, 0)
        let outR = locateChannel(output.list, 1)
        unduck_render(state,
                      UnduckSrc(base: UnsafePointer(inL.base), stride: Int32(inL.stride)),
                      UnduckSrc(base: UnsafePointer(inR.base), stride: Int32(inR.stride)),
                      Int32(inL.frames),
                      UnduckDst(base: outL.base, stride: Int32(outL.stride)),
                      UnduckDst(base: outR.base, stride: Int32(outR.stride)),
                      Int32(outL.frames))

        for frame in 0..<(frames / 2) {
            #expect(isClose(output.sample(channel: 0, frame: frame), 0.5))
        }
        for frame in (frames / 2)..<frames {
            #expect(output.sample(channel: 0, frame: frame) == 0)
            #expect(output.sample(channel: 1, frame: frame) == 0)
        }
    }

    @Test("The limiter holds the ceiling and reports what it did")
    func limiterHoldsCeiling() {
        let frames = 4096
        let input = TestBufferList(channelsPerBuffer: [2], frames: frames)
        let output = TestBufferList(channelsPerBuffer: [2], frames: frames)
        let inL = locateChannel(input.list, 0)
        let inR = locateChannel(input.list, 1)
        for frame in 0..<frames {
            inL.base![frame * inL.stride] = 0.8
            inR.base![frame * inR.stride] = 0.8
        }

        let state = UnsafeMutablePointer<UnduckRenderState>.allocate(capacity: 1)
        defer { state.deallocate() }
        unduck_init(state, 48_000, 4.0, 1.0)   // +12 dB into a 0 dBFS ceiling

        let outL = locateChannel(output.list, 0)
        let outR = locateChannel(output.list, 1)
        unduck_render(state,
                      UnduckSrc(base: UnsafePointer(inL.base), stride: Int32(inL.stride)),
                      UnduckSrc(base: UnsafePointer(inR.base), stride: Int32(inR.stride)),
                      Int32(frames),
                      UnduckDst(base: outL.base, stride: Int32(outL.stride)),
                      UnduckDst(base: outR.base, stride: Int32(outR.stride)),
                      Int32(frames))

        #expect(isClose(output.sample(channel: 0, frame: frames - 1), 1.0, 0.02))
        #expect(state.pointee.limitDB > 0)      // limiting is reported, not hidden
        // Once the ~2 ms attack has engaged, nothing gets past the ceiling. (The
        // very start of the block does overshoot, as any finite-attack limiter
        // does; the boosted domain has ~25 dB of headroom above it for exactly that.)
        for frame in (frames - 100)..<frames {
            #expect(output.sample(channel: 0, frame: frame) <= 1.01)
        }
    }
}
