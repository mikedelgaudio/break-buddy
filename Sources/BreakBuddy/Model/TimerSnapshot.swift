import Foundation

/// Timer state saved to disk so a restart picks up where the app left off.
struct TimerSnapshot: Codable {
    struct SavedBreak: Codable {
        var kinds: [BreakKind]
        var endsAt: Date
    }

    var savedAt: Date
    var worked: [String: TimeInterval]
    var pausedUntil: Date?
    var presentationMode: Bool
    var presentationUntil: Date?
    var snoozedUntil: Date?
    var activeBreak: SavedBreak?
}

struct SnapshotStore {
    let url: URL

    func load() -> TimerSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TimerSnapshot.self, from: data)
    }

    func save(_ snapshot: TimerSnapshot) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
