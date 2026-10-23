import AppKit
import CoreAudio
import CoreMediaIO

/// Reads which processes are capturing audio (Core Audio process objects, macOS 14.4+) and
/// whether any camera is running (CoreMediaIO). Neither requires a permission prompt.
final class CoreAudioDetector: ActivityDetector {
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let system = AudioObjectID(kAudioObjectSystemObject)

    func read() -> DetectionReading {
        guard let processes = audioObjects(system, kAudioHardwarePropertyProcessObjectList) else {
            return DetectionReading(error: "Core Audio process list unavailable")
        }
        var signals: Set<ActivitySignal> = []
        var anyProcessInput = false
        for process in processes where uint32(process, kAudioProcessPropertyIsRunningInput) == 1 {
            guard let pid = pid(process), pid != ownPID else { continue }
            anyProcessInput = true
            let (appID, appName) = identify(pid: pid, bundleID: string(process, kAudioProcessPropertyBundleID))
            signals.insert(ActivitySignal(kind: .microphone, appID: appID, appName: appName))
        }
        // Input running with no process claiming it: still evidence, just unattributed.
        if !anyProcessInput, inputDeviceRunning() {
            signals.insert(ActivitySignal(kind: .microphone))
        }
        switch cameraRunning() {
        case .some(true): signals.insert(ActivitySignal(kind: .camera))
        case .some(false): break
        case nil: return DetectionReading(signals: signals, error: "Camera state unavailable")
        }
        return DetectionReading(signals: signals)
    }

    /// Maps helper processes (e.g. `com.google.Chrome.helper`) to their parent app.
    private func identify(pid: pid_t, bundleID: String?) -> (String?, String?) {
        var appID = bundleID.flatMap { $0.isEmpty ? nil : $0 }
        if let id = appID, let range = id.range(of: ".helper", options: .caseInsensitive) {
            appID = String(id[..<range.lowerBound])
        }
        if let id = appID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            return (id, app.localizedName ?? id)
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            return (appID ?? app.bundleIdentifier, app.localizedName ?? appID)
        }
        var buffer = [CChar](repeating: 0, count: 256)
        let name = proc_name(pid, &buffer, UInt32(buffer.count)) > 0
            ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : nil
        return (appID, name ?? appID)
    }

    private func inputDeviceRunning() -> Bool {
        for device in audioObjects(system, kAudioHardwarePropertyDevices) ?? [] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { continue }
            if uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1 { return true }
        }
        return false
    }

    private func cameraRunning() -> Bool? {
        var address = cmioAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == noErr else { return nil }
        for device in devices {
            var running = cmioAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            var value: UInt32 = 0
            if CMIOObjectGetPropertyData(device, &running, 0, nil, 4, &used, &value) == noErr, value != 0 { return true }
        }
        return false
    }

    // MARK: Core Audio plumbing

    private func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func cmioAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal), mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private func audioObjects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID]? {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func pid(_ object: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
