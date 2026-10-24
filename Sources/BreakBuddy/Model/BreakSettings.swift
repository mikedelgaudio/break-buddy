import Foundation

enum BreakKind: String, Codable, CaseIterable, Comparable {
    case eye, move

    var label: String { self == .eye ? "Eye" : "Movement" }

    static func < (a: BreakKind, b: BreakKind) -> Bool { a.rawValue < b.rawValue }
}

struct BreakSettings: Codable, Equatable {
    var eyeIntervalMinutes: Double = 20
    var eyeDurationSeconds: Double = 20
    var moveIntervalMinutes: Double = 50
    var moveDurationSeconds: Double = 120
    var snoozeMinutes: Double = 5
    var graceSeconds: Double = 60
    var workingHoursEnabled = true
    /// Calendar weekdays (1 = Sunday … 7 = Saturday).
    var workDays: Set<Int> = [2, 3, 4, 5, 6]
    var workStartMinutes = 9 * 60
    var workEndMinutes = 18 * 60
    /// Time away (locked, asleep or idle) credits each break type whose duration it covers.
    var creditTimeAway = true
    /// No keyboard/mouse input from the person for this long (outside meetings) counts as away.
    var idleMinutes: Double = 5
    var detectMicrophone = true
    var detectCamera = true
    /// Bundle IDs whose microphone use never counts as a call (dictation, Siri, sound recognition…).
    var ignoredApps: [String] = BreakSettings.defaultIgnoredApps
    var launchAtLogin = false

    static let defaultIgnoredApps = [
        "com.apple.CoreSpeech",
        "com.apple.SpeechRecognitionCore.speechrecognitiond",
        "com.apple.assistantd",
        "com.apple.accessibility.heard",
        "com.apple.universalaccessd",
        "com.apple.cmio.ContinuityCaptureAgent",
    ]

    func interval(_ kind: BreakKind) -> TimeInterval {
        (kind == .eye ? eyeIntervalMinutes : moveIntervalMinutes) * 60
    }

    func duration(_ kind: BreakKind) -> TimeInterval {
        kind == .eye ? eyeDurationSeconds : moveDurationSeconds
    }

    func isWorkingTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard workingHoursEnabled else { return true }
        let c = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = c.weekday, workDays.contains(weekday) else { return false }
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return minutes >= workStartMinutes && minutes < workEndMinutes
    }

    /// Overlays a partial JSON object onto these settings, so stored files missing
    /// newer keys (and partial updates from the test harness) keep their defaults.
    func merging(_ patch: [String: Any]) throws -> BreakSettings {
        var base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
        base.merge(patch) { _, new in new }
        return try JSONDecoder().decode(BreakSettings.self, from: JSONSerialization.data(withJSONObject: base))
    }
}

/// Settings live in a JSON file: Application Support normally, the test state dir under E2E.
struct SettingsStore {
    let url: URL

    func load() -> BreakSettings {
        guard let data = try? Data(contentsOf: url),
              let patch = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = try? BreakSettings().merging(patch)
        else { return BreakSettings() }
        return settings
    }

    func save(_ settings: BreakSettings) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(settings).write(to: url, options: .atomic)
    }
}
