import Foundation

enum SuppressionReason: Hashable, Comparable {
    case presentationMode
    /// Injected by the E2E harness until real detectors exist.
    case simulated(String)

    var label: String {
        switch self {
        case .presentationMode: "Presentation mode"
        case .simulated(let name): "Simulated \(name)"
        }
    }

    static func < (a: SuppressionReason, b: SuppressionReason) -> Bool { a.label < b.label }
}

/// Decides when pending breaks may interrupt. Holds them while suppressed, waits out a
/// grace period once every reason clears, then offers one combined reminder.
struct ReminderCoordinator {
    private(set) var graceEndsAt: Date?
    private(set) var snoozedUntil: Date?
    private var wasSuppressed = false
    private var lastRemindedAt: Date?
    private var remindedKinds: Set<BreakKind> = []

    /// Returns the break types to remind about now, or nil to stay quiet.
    mutating func evaluate(now: Date, due: Set<BreakKind>, suppressed: Bool, settings: BreakSettings) -> Set<BreakKind>? {
        updateSuppression(suppressed, now: now, settings: settings)
        if suppressed { return nil }
        if let grace = graceEndsAt {
            guard now >= grace else { return nil }
            graceEndsAt = nil
        }
        guard !due.isEmpty else {
            lastRemindedAt = nil
            remindedKinds = []
            return nil
        }
        if let snooze = snoozedUntil {
            guard now >= snooze else { return nil }
            snoozedUntil = nil
        }
        // An unanswered reminder repeats after the snooze interval, never every tick;
        // a newly due type joins immediately as one combined reminder.
        if let last = lastRemindedAt, due.isSubset(of: remindedKinds),
           now < last.addingTimeInterval(settings.snoozeMinutes * 60) {
            return nil
        }
        lastRemindedAt = now
        remindedKinds = due
        return due
    }

    /// Called on every tick and whenever a suppression reason changes, so the grace
    /// period starts the moment the last reason clears rather than on the next tick.
    mutating func updateSuppression(_ suppressed: Bool, now: Date, settings: BreakSettings) {
        if suppressed {
            wasSuppressed = true
            graceEndsAt = nil
        } else if wasSuppressed {
            wasSuppressed = false
            graceEndsAt = now.addingTimeInterval(settings.graceSeconds)
        }
    }

    mutating func snooze(now: Date, settings: BreakSettings) {
        snoozedUntil = now.addingTimeInterval(settings.snoozeMinutes * 60)
    }

    /// Completed or credited types no longer count as reminded; the rest keep their
    /// repeat timer so a still-overdue type isn't re-announced the instant a break ends.
    mutating func credit(_ kinds: Set<BreakKind>) {
        remindedKinds.subtract(kinds)
        if remindedKinds.isEmpty { lastRemindedAt = nil }
        snoozedUntil = nil
    }
}
