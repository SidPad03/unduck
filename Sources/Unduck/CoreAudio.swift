import Foundation
import CoreAudio

// Thin, defensive wrappers over the HAL C property API. Everything returns
// optionals instead of trapping so a transient HAL hiccup never crashes the app.
//
// Every call here is a synchronous XPC round-trip to coreaudiod, so the wrappers
// make exactly one of them per read. The `AudioObjectHasProperty` pre-check these
// used to do doubled the round-trip count for nothing: a property the object does
// not have already comes back as a non-noErr status from the Get itself.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Read a fixed-size scalar property (UInt32, pid_t, AudioObjectID, etc.).
    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> T? {
        var addr = address(selector, scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    /// Read a CFString property (device UID, bundle ID, …).
    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    /// Read a variable-length array property of a fixed element type.
    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: T.Type,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T] {
        var addr = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        // Uninitialised storage: no zero-fill pass, and no per-call scratch
        // allocation just to synthesise a zero element to repeat.
        return [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            var byteSize = size
            let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &byteSize, buffer.baseAddress!)
            initialized = status == noErr ? min(count, Int(byteSize) / MemoryLayout<T>.stride) : 0
        }
    }

    // MARK: convenience

    static var defaultOutputDevice: AudioObjectID? {
        scalar(system, kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static var processObjects: [AudioObjectID] {
        array(system, kAudioHardwarePropertyProcessObjectList, AudioObjectID.self)
    }

    /// Our own process object. Fixed for the lifetime of the process, so it is
    /// resolved once instead of on every call-state change.
    static let ownProcessObject: AudioObjectID? = processObject(forPID: getpid())

    static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidValue = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { pidPtr in
            AudioObjectGetPropertyData(system, &addr, UInt32(MemoryLayout<pid_t>.size), pidPtr, &size, &object)
        }
        return (status == noErr && object != AudioObjectID(kAudioObjectUnknown)) ? object : nil
    }

    static func bundleID(ofProcess object: AudioObjectID) -> String? {
        string(object, kAudioProcessPropertyBundleID)
    }

    static func isRunningInput(_ object: AudioObjectID) -> Bool {
        (scalar(object, kAudioProcessPropertyIsRunningInput, UInt32(0)) ?? 0) != 0
    }

    static func tapStreamFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        scalar(tap, kAudioTapPropertyFormat, AudioStreamBasicDescription())
    }

    static func nominalSampleRate(_ device: AudioObjectID) -> Double? {
        scalar(device, kAudioDevicePropertyNominalSampleRate, Double(0)).flatMap { $0 > 0 ? $0 : nil }
    }

    /// Which channels of the output stream the device wants stereo content in,
    /// as 0-based indices. On a two-channel device this is the only pair there
    /// is; on a Studio Display (an eight-channel interleaved stream) it picks
    /// front L/R out of the eight, and writing anywhere else is what turns media
    /// into noise. Mono devices report the same channel twice.
    static func stereoChannels(_ device: AudioObjectID) -> (left: Int, right: Int)? {
        let pair = array(device, kAudioDevicePropertyPreferredChannelsForStereo, UInt32.self,
                         scope: kAudioObjectPropertyScopeOutput)
        guard pair.count >= 2, pair[0] >= 1, pair[1] >= 1 else { return nil }
        return (Int(pair[0]) - 1, Int(pair[1]) - 1)   // the property is 1-based
    }

    /// Total output channels the device presents, summed across its buffers.
    static func outputChannelCount(_ device: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
