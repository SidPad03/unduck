import Foundation
import CoreAudio
import CUnduckRender
import OSLog

private let log = Logger(subsystem: "com.sigmanet.unduck", category: "AudioRouter")

/// Owns the process tap + private aggregate device + IOProc that captures media
/// audio, boosts it (to cancel FaceTime's duck), and re-injects it to the real
/// output device. Build/teardown is all-or-nothing; teardown is fail-open
/// (un-mutes media first) and idempotent.
///
/// Every HAL object call is a synchronous XPC round-trip and the build path makes
/// several that routinely run into the hundreds of milliseconds
/// (`AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`,
/// `AudioDeviceStart`). Running those inline from a SwiftUI toggle froze the menu
/// for the duration, so they are serialised onto a private queue and report back
/// on main.
final class AudioRouter {

    enum RouterError: Error, CustomStringConvertible {
        case noOutputDevice, noOutputUID, tapCreateFailed(OSStatus), aggregateCreateFailed(OSStatus), ioProcFailed(OSStatus), startFailed(OSStatus)
        var description: String {
            switch self {
            case .noOutputDevice: return "no default output device"
            case .noOutputUID: return "default output device has no UID"
            case .tapCreateFailed(let s): return "AudioHardwareCreateProcessTap failed (\(s))"
            case .aggregateCreateFailed(let s): return "AudioHardwareCreateAggregateDevice failed (\(s))"
            case .ioProcFailed(let s): return "AudioDeviceCreateIOProcIDWithBlock failed (\(s))"
            case .startFailed(let s): return "AudioDeviceStart failed (\(s))"
            }
        }
    }

    static let aggregateUIDPrefix = "com.sigmanet.unduck.aggregate."

    /// Serialises the whole HAL object lifecycle. Nothing here touches the UI.
    private let queue = DispatchQueue(label: "com.sigmanet.unduck.router", qos: .userInitiated)

    // Owned by `queue`.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// The render state is allocated on `queue` and sampled by the meter on main,
    /// so the pointer lives behind a lock. The audio thread does not go through
    /// this - it captures the raw pointer for the life of the IOProc, and the
    /// IOProc is always stopped and destroyed before the state is freed.
    private let stateLock = NSLock()
    private var renderState: UnsafeMutablePointer<UnduckRenderState>?

    private func withRenderState<R>(_ body: (UnsafeMutablePointer<UnduckRenderState>?) -> R) -> R {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(renderState)
    }

    /// dB of duck we expect the system to apply to our re-injected output. The
    /// limiter ceiling is derived from this so we clamp in the right domain.
    var expectedDuckDB: Float = 25.0

    // MARK: lifecycle

    /// Build the tap + aggregate + IOProc off the main thread. `excludeProcesses`
    /// = our own process object + the communication app(s), so their audio stays
    /// on the normal path. `completion` runs on the main queue.
    func start(excludeProcesses: [AudioObjectID],
               boostDB: Float,
               completion: @escaping (Result<Void, Error>) -> Void) {
        let duckDB = expectedDuckDB
        queue.async { [self] in
            let result: Result<Void, Error>
            do {
                try buildGraph(excludeProcesses: excludeProcesses, boostDB: boostDB, duckDB: duckDB)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Tear down in the background. Safe to call repeatedly and from any thread.
    func stop() {
        queue.async { [self] in teardown() }
    }

    /// Tear down and wait. Used on quit and sleep, where the process must not get
    /// away with the tap still installed - that would leave media apps muted.
    func stopSynchronously() {
        queue.sync { teardown() }
    }

    private func buildGraph(excludeProcesses: [AudioObjectID], boostDB: Float, duckDB: Float) throws {
        teardown()   // idempotent; a rebuild always starts from a clean graph

        guard let outputDevice = CA.defaultOutputDevice, outputDevice != 0 else { throw RouterError.noOutputDevice }
        guard let outputUID = CA.deviceUID(outputDevice) else { throw RouterError.noOutputUID }

        // 1) Tap everything EXCEPT the excluded processes, muting the originals so
        //    only our re-injected copy is heard. NOTE: the ...ButExcludeProcesses
        //    initializer sets the include/exclude polarity itself - do NOT touch
        //    isExclusive afterward or the set inverts (silent failure, spec §3.1).
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excludeProcesses)
        tapDescription.uuid = UUID()
        tapDescription.name = "Unduck Media Tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .mutedWhenTapped

        var newTap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTap)
        guard tapStatus == noErr, newTap != AudioObjectID(kAudioObjectUnknown) else {
            throw RouterError.tapCreateFailed(tapStatus)
        }
        tapID = newTap

        // 2) Private aggregate: real output device as the main sub-device (required -
        //    an empty sub-device list yields all-zero samples with no error), plus
        //    our tap. Same clock, so no sample-rate conversion between cap + playback.
        let aggUID = Self.aggregateUIDPrefix + UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Unduck",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [[kAudioSubDeviceUIDKey as String: outputUID]],
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapDriftCompensationKey as String: true,
                kAudioSubTapUIDKey as String: tapDescription.uuid.uuidString,
            ]],
        ]
        var newAgg = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAgg)
        guard aggStatus == noErr, newAgg != AudioObjectID(kAudioObjectUnknown) else {
            AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown)
            throw RouterError.aggregateCreateFailed(aggStatus)
        }
        aggregateID = newAgg

        // 3) Render state. Ceiling lives in OUR boosted domain: keep output below
        //    (duck - 0.5) dBFS so that after the system attenuates by `duck`, the
        //    final level lands under -0.5 dBFS.
        let state = UnsafeMutablePointer<UnduckRenderState>.allocate(capacity: 1)
        let ceiling = powf(10.0, (duckDB - 0.5) / 20.0)
        unduck_init(state, 48_000.0, powf(10.0, boostDB / 20.0), ceiling)
        stateLock.lock(); renderState = state; stateLock.unlock()

        // 4) IOProc: tap audio arrives as input, real device is the output. Copy
        //    input → output through the C render core. Captures only the raw
        //    pointer - no Swift objects, no ARC on the audio thread.
        var newProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, nil) {
            _, inInputData, _, outOutputData, _ in
            let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard outABL.count > 0,
                  let out0 = outABL[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let outFrames = Int(outABL[0].mDataByteSize) / MemoryLayout<Float>.size
            let out1 = outABL.count > 1 ? outABL[1].mData?.assumingMemoryBound(to: Float.self) : nil

            let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let in0 = inABL.count > 0 ? inABL[0].mData?.assumingMemoryBound(to: Float.self) : nil
            let in1 = inABL.count > 1 ? inABL[1].mData?.assumingMemoryBound(to: Float.self) : nil
            // The tap and the device can disagree about block size. Pass both counts
            // so the render core never reads past the tap's buffer; when the tap gave
            // us nothing there is no buffer to overrun, so let it render silence
            // through the loop and keep the gain/limiter state gliding.
            let inFrames = in0 == nil ? outFrames : Int(inABL[0].mDataByteSize) / MemoryLayout<Float>.size

            unduck_render(state,
                          in0, in1, Int32(inABL.count), Int32(inFrames),
                          out0, out1, Int32(outABL.count), Int32(outFrames))
        }
        guard procStatus == noErr, let proc = newProc else {
            teardown(); throw RouterError.ioProcFailed(procStatus)
        }
        ioProcID = proc

        let startStatus = AudioDeviceStart(aggregateID, proc)
        guard startStatus == noErr else {
            teardown(); throw RouterError.startFailed(startStatus)
        }

        log.info("router started (agg=\(self.aggregateID), tap=\(self.tapID), boost=\(boostDB)dB, output=\(outputUID, privacy: .public))")
    }

    /// Fail-open teardown: un-mute the media FIRST (destroy the tap) so a stall in
    /// a later step can never leave apps silent, then release everything else.
    /// Idempotent. Runs on `queue`. (NOT called from a signal handler - HAL reaping
    /// covers hard kills; see spec correction.)
    private func teardown() {
        if let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
            ioProcID = nil
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)   // <- un-mutes media apps
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        if aggregateID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        // Clear under the lock before freeing, so a concurrent meter read on main
        // can never see a dangling pointer. The IOProc is already gone by here.
        stateLock.lock()
        let stale = renderState
        renderState = nil
        stateLock.unlock()
        stale?.deallocate()
    }

    // MARK: control + metering

    /// Safe from any thread.
    func setBoost(dB: Float) {
        let gain = powf(10.0, dB / 20.0)
        withRenderState { ptr in
            if let ptr { unduck_set_gain(ptr, gain) }
        }
    }

    /// One lock-guarded snapshot instead of two unsynchronised pointer reads.
    /// Returns zeroes when no graph is up. Safe from any thread.
    func meters() -> (peak: Float, limitDB: Float) {
        withRenderState { ptr in
            guard let ptr else { return (Float(0), Float(0)) }
            return (ptr.pointee.peak, ptr.pointee.limitDB)
        }
    }

    /// Destroy any private aggregates our app left behind after a crash. Call at
    /// launch. Runs in the background - enumerating devices is a pile of HAL IPC.
    static func sweepOrphans() {
        DispatchQueue.global(qos: .utility).async {
            for device in CA.array(CA.system, kAudioHardwarePropertyDevices, AudioObjectID.self) {
                if let uid = CA.deviceUID(device), uid.hasPrefix(aggregateUIDPrefix) {
                    AudioHardwareDestroyAggregateDevice(device)
                    log.notice("swept orphan aggregate \(uid, privacy: .public)")
                }
            }
        }
    }
}
