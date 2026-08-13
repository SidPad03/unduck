import Foundation
import CoreAudio

// Locating a channel inside an AudioBufferList.
//
// Nothing about a buffer list's shape can be assumed, and the differences
// between devices are exactly what used to turn media into noise on anything but
// the built-in speakers:
//
//   built-in speakers        1 buffer  x 2ch interleaved  @ 48 kHz
//   Studio Display speakers  1 buffer  x 8ch interleaved  @ 48 kHz
//   the process tap          1 buffer  x 2ch interleaved
//
// The old IOProc read a buffer's frame count as mDataByteSize / sizeof(Float)
// and treated buffer[0]/buffer[1] as L/R. On the built-in speakers that happened
// to be a correct verbatim copy, because the tap and the device had the
// identical 2ch interleaved layout. On the display it wrote a 2-channel
// interleaved stream into the first quarter of an 8-channel one, so one frame of
// media landed spread across four output frames, rotating through all eight
// speaker positions - audible as quarter-speed, garbled audio. So: measure,
// never assume.

/// One channel located inside a buffer list: where it starts, how far apart its
/// samples are (in floats), and how many frames the owning buffer holds.
struct ChannelRef {
    var base: UnsafeMutablePointer<Float>?
    var stride: Int = 0
    var frames: Int = 0
}

/// Walk the buffer list to the given channel, counting channels across buffers.
/// Handles both layouts: an N-channel interleaved buffer yields stride N, a
/// one-channel-per-buffer (planar) list yields stride 1. Realtime-safe: pointer
/// arithmetic only, no allocation and no ARC.
@inline(__always)
func locateChannel(_ list: UnsafeMutableAudioBufferListPointer, _ channel: Int) -> ChannelRef {
    guard channel >= 0 else { return ChannelRef() }
    var remaining = channel
    for i in 0..<list.count {
        let buffer = list[i]
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0 else { continue }
        if remaining < channels {
            guard let base = buffer.mData?.assumingMemoryBound(to: Float.self) else { return ChannelRef() }
            return ChannelRef(base: base + remaining,
                              stride: channels,
                              frames: Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size))
        }
        remaining -= channels
    }
    return ChannelRef()
}

/// Zero every buffer in the list. We only ever fill two channels, and Core Audio
/// does not hand out cleared output buffers - so without this, every other
/// channel of a multi-channel device replays whatever was left in the buffer.
@inline(__always)
func silenceBuffers(_ list: UnsafeMutableAudioBufferListPointer) {
    for i in 0..<list.count {
        if let data = list[i].mData { memset(data, 0, Int(list[i].mDataByteSize)) }
    }
}
