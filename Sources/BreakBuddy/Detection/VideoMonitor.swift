import AppKit
import IOKit.pwr_mgt

/// Which apps are keeping the display awake. Video players (Chrome's "Video Wake Lock",
/// Safari, QuickTime, slideshows) hold a display-sleep assertion only while playing, so this
/// separates "watching" from "stepped away" when there's no keyboard or mouse input. Agents'
/// keep-awake uses system-sleep assertions, which are ignored here. Needs no permission.
protocol VideoMonitor: AnyObject {
    /// App names holding a display-sleep assertion right now.
    func displaySleepHolders() -> [String]
}

final class PowerAssertionVideoMonitor: VideoMonitor {
    private static let displayTypes: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func displaySleepHolders() -> [String] {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let byProcess = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return [] }
        var names: Set<String> = []
        for (pid, assertions) in byProcess where pid.int32Value != ownPID {
            guard assertions.contains(where: { Self.displayTypes.contains($0[kIOPMAssertionTypeKey] as? String ?? "") }) else { continue }
            let pid = pid.int32Value
            let identity = AppIdentity.identify(pid: pid, bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier)
            names.insert(identity.name ?? identity.id ?? "pid \(pid)")
        }
        return names.sorted()
    }
}

final class FakeVideoMonitor: VideoMonitor {
    var holders: Set<String> = []

    func displaySleepHolders() -> [String] { holders.sorted() }
}
