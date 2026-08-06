import Foundation
import CoreAudio
import CUnduckRender
import OSLog

private let log = Logger(subsystem: "com.sigmanet.unduck", category: "AudioRouter")

/// Owns the process tap + private aggregate device + IOProc that captures media
/// audio, boosts it (to cancel FaceTime's duck), and re-injects it to the real
/// output device. Build/teardown is all-or-nothing; teardown is fail-open
/// (un-mutes media first) and idempotent.
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

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var statePtr: UnsafeMutablePointer<UnduckRenderState>?
    private(set) var isRunning = false

    /// dB of duck we expect the system to apply to our re-injected output. The
    /// limiter ceiling is derived from this so we clamp in the right domain.
    var expectedDuckDB: Float = 25.0

    // MARK: lifecycle

    /// Build the tap + aggregate + IOProc. `excludeProcesses` = our own process
    /// object + the communication app(s), so their audio stays on the normal path.
    func start(excludeProcesses: [AudioObjectID], boostDB: Float) throws {
        guard !isRunning else { return }

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
        let ceiling = powf(10.0, (expectedDuckDB - 0.5) / 20.0)
        unduck_init(state, 48_000.0, powf(10.0, boostDB / 20.0), ceiling)
        statePtr = state

        // 4) IOProc: tap audio arrives as input, real device is the output. Copy
        //    input → output through the C render core. Captures only the raw
        //    pointer - no Swift objects, no ARC on the audio thread.
        var newProc: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, nil) {
            _, inInputData, _, outOutputData, _ in
            let inABL = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outABL = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard outABL.count > 0 else { return }

            let frames = Int(outABL[0].mDataByteSize) / MemoryLayout<Float>.size
            let in0 = inABL.count > 0 ? inABL[0].mData?.assumingMemoryBound(to: Float.self) : nil
            let in1 = inABL.count > 1 ? inABL[1].mData?.assumingMemoryBound(to: Float.self) : nil
            let out0 = outABL[0].mData?.assumingMemoryBound(to: Float.self)
            let out1 = outABL.count > 1 ? outABL[1].mData?.assumingMemoryBound(to: Float.self) : nil

            unduck_render(state,
                          in0, in1, Int32(inABL.count),
                          out0, out1, Int32(outABL.count),
                          Int32(frames))
        }
        guard procStatus == noErr, let proc = newProc else {
            teardown(); throw RouterError.ioProcFailed(procStatus)
        }
        ioProcID = proc

        let startStatus = AudioDeviceStart(aggregateID, proc)
        guard startStatus == noErr else {
            teardown(); throw RouterError.startFailed(startStatus)
        }

        isRunning = true
        log.info("router started (agg=\(self.aggregateID), tap=\(self.tapID), boost=\(boostDB)dB, output=\(outputUID, privacy: .public))")
    }

    func stop() { teardown() }

    /// Fail-open teardown: un-mute the media FIRST (destroy the tap) so a stall in
    /// a later step can never leave apps silent, then release everything else.
    /// Safe to call repeatedly and from any thread. (NOT called from a signal
    /// handler - HAL reaping covers hard kills; see spec correction.)
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
        if let s = statePtr { s.deallocate(); statePtr = nil }
        isRunning = false
    }

    // MARK: control + metering

    func setBoost(dB: Float) { if let s = statePtr { unduck_set_gain(s, powf(10.0, dB / 20.0)) } }

    var meterPeak: Float { statePtr?.pointee.peak ?? 0 }
    var limitingDB: Float { statePtr?.pointee.limitDB ?? 0 }

    /// Destroy any private aggregates our app left behind after a crash. Call at launch.
    static func sweepOrphans() {
        for device in CA.array(CA.system, kAudioHardwarePropertyDevices, AudioObjectID.self) {
            if let uid = CA.deviceUID(device), uid.hasPrefix(aggregateUIDPrefix) {
                AudioHardwareDestroyAggregateDevice(device)
                log.notice("swept orphan aggregate \(uid, privacy: .public)")
            }
        }
    }
}
