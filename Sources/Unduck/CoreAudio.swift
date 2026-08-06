import Foundation
import CoreAudio

// Thin, defensive wrappers over the HAL C property API. Everything returns
// optionals instead of trapping so a transient HAL hiccup never crashes the app.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// Read a fixed-size scalar property (UInt32, pid_t, AudioObjectID, etc.).
    static func scalar<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
        var addr = address(selector)
        guard AudioObjectHasProperty(object, &addr) else { return nil }
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
        guard AudioObjectHasProperty(object, &addr) else { return nil }
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    /// Read a variable-length array property of a fixed element type.
    static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: T.Type) -> [T] {
        var addr = address(selector)
        guard AudioObjectHasProperty(object, &addr) else { return [] }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var buffer = [T](repeating: memZero(), count: count)
        let status = buffer.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? buffer : []
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
}

// Zero-initialised value for numeric HAL element types.
private func memZero<T>() -> T {
    let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { ptr.deallocate() }
    memset(ptr, 0, MemoryLayout<T>.size)
    return ptr.pointee
}
