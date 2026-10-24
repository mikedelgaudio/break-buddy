import Foundation

/// Per-type accumulated work time. Knows nothing about meetings or delivery.
struct BreakScheduler {
    private(set) var worked: [BreakKind: TimeInterval] = [.eye: 0, .move: 0]

    mutating func accumulate(_ seconds: TimeInterval) {
        for kind in BreakKind.allCases { worked[kind, default: 0] += seconds }
    }

    mutating func restore(_ saved: [BreakKind: TimeInterval]) {
        worked = saved
    }

    /// Takes back work time that turned out to be idle.
    mutating func refund(_ seconds: TimeInterval) {
        for kind in BreakKind.allCases { worked[kind] = max(0, workedSeconds(kind) - seconds) }
    }

    mutating func reset(_ kinds: Set<BreakKind>) {
        for kind in kinds { worked[kind] = 0 }
    }

    func workedSeconds(_ kind: BreakKind) -> TimeInterval { worked[kind, default: 0] }

    func remaining(_ kind: BreakKind, _ settings: BreakSettings) -> TimeInterval {
        max(0, settings.interval(kind) - workedSeconds(kind))
    }

    func due(_ settings: BreakSettings) -> Set<BreakKind> {
        Set(BreakKind.allCases.filter { workedSeconds($0) >= settings.interval($0) })
    }
}
