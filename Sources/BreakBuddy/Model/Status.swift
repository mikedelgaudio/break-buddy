import Foundation

/// Human-readable status, shown in the menu and captured by the E2E harness.
extension AppModel {
    var statusText: String {
        if isAway {
            return (["Away"] + awayReasons.sorted().map(\.label)).joined(separator: " · ")
        }
        if let active = activeBreak {
            return "On break · \(Self.short(active.endsAt.timeIntervalSince(now))) left"
        }
        if let until = pausedUntil {
            return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        }
        let reasons = suppressionReasons
        if !reasons.isEmpty {
            return (["Deferred"] + reasons.map(\.label) + (Self.overdue(due).map { [$0] } ?? [])).joined(separator: " · ")
        }
        if let grace = coordinator.graceEndsAt, !due.isEmpty {
            return "Catch-up break in \(Self.short(grace.timeIntervalSince(now)))"
        }
        if !isWorkingTime { return "Outside working hours" }
        if let overdue = Self.overdue(due) { return overdue }
        return "Eyes in \(Self.short(scheduler.remaining(.eye, settings))) · Move in \(Self.short(scheduler.remaining(.move, settings)))"
    }

    var menuBarSymbol: String {
        if awayReasons == [.idle] { return "zzz" }
        if isAway { return "lock" }
        if activeBreak != nil { return "cup.and.saucer" }
        if pausedUntil != nil { return "pause.circle" }
        if !suppressionReasons.isEmpty { return "moon" }
        if !due.isEmpty { return "exclamationmark.circle" }
        return "eye"
    }

    var menuBarText: String {
        if let active = activeBreak { return Self.short(active.endsAt.timeIntervalSince(now)) }
        if isAway || pausedUntil != nil || !suppressionReasons.isEmpty || !due.isEmpty || !isWorkingTime { return "" }
        return Self.short(BreakKind.allCases.map { scheduler.remaining($0, settings) }.min() ?? 0)
    }

    var detectionStatusText: String {
        let watching = [settings.detectMicrophone ? "microphone" : nil, settings.detectCamera ? "camera" : nil].compactMap { $0 }
        if watching.isEmpty { return "Meeting detection off" }
        if detectionError != nil { return "Meeting detection unavailable" }
        return "Watching \(watching.joined(separator: " and "))"
    }

    static func overdue(_ kinds: Set<BreakKind>) -> String? {
        switch kinds {
        case [.eye]: "Eye break overdue"
        case [.move]: "Movement break overdue"
        case [.eye, .move]: "Eye and movement breaks overdue"
        default: nil
        }
    }

    static func short(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return s < 60 ? "\(s)s" : "\((s + 59) / 60)m"
    }
}
