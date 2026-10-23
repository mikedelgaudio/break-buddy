import Foundation

protocol AppClock: AnyObject {
    var now: Date { get }
}

final class SystemClock: AppClock {
    var now: Date { Date() }
}

/// Only moves when the E2E harness tells it to, so scenarios are deterministic.
final class ManualClock: AppClock {
    var now: Date

    init(start: Date) { now = start }
}
