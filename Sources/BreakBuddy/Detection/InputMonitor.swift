import CoreGraphics
import Foundation

/// How long since the person last touched the keyboard, mouse or trackpad.
protocol InputMonitor: AnyObject {
    func secondsSinceHumanInput(now: Date) -> TimeInterval
}

/// Reads the HID system's idle time: hardware input only. Agents that work without posting
/// input events (terminals, builds, in-page browser automation) don't reset it, so an awake
/// Mac with agents running still reads as "you're away". Tools that post synthetic HID events
/// with Accessibility permission (computer-use agents, mouse jigglers) may still reset it.
final class HardwareInputMonitor: InputMonitor {
    static let anyInput = CGEventType(rawValue: ~0)!

    func secondsSinceHumanInput(now: Date) -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: Self.anyInput)
    }

    /// Idle time across every source, synthetic events included. Diagnostic only.
    static func secondsSinceAnyInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

/// E2E stand-in. With no recorded input the person counts as present, so scenarios that
/// don't care about idle aren't affected by it.
final class FakeInputMonitor: InputMonitor {
    var lastHumanInput: Date?

    func secondsSinceHumanInput(now: Date) -> TimeInterval {
        lastHumanInput.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }
}
