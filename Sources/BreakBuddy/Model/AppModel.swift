import Foundation
import Observation

struct ActiveBreak: Equatable {
    var kinds: Set<BreakKind>
    var endsAt: Date
}

protocol ReminderSink: AnyObject {
    func remind(_ kinds: Set<BreakKind>, catchUp: Bool)
    func breakFinished(_ kinds: Set<BreakKind>)
    func clearReminders()
}

/// Owns the timers and every user action. The menu, notifications and the E2E control
/// channel all drive the app through these same methods.
@Observable
final class AppModel {
    /// A tick further apart than this means sleep or a clock change: reconcile, don't replay.
    static let maxTickGap: TimeInterval = 15

    private(set) var settings: BreakSettings
    private(set) var now: Date
    private(set) var scheduler = BreakScheduler()
    private(set) var coordinator = ReminderCoordinator()
    private(set) var presentationMode = false
    private(set) var presentationUntil: Date?
    private(set) var simulatedSignals: Set<String> = []
    private(set) var pausedUntil: Date?
    private(set) var activeBreak: ActiveBreak?
    private(set) var remindersDelivered = 0

    @ObservationIgnored let clock: AppClock
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored weak var sink: ReminderSink?
    @ObservationIgnored var onEvent: (String, [String: Any]) -> Void = { _, _ in }
    @ObservationIgnored private var lastTick: Date
    @ObservationIgnored private var deferredWhileDue = false
    @ObservationIgnored private var timer: Timer?

    init(clock: AppClock, store: SettingsStore) {
        self.clock = clock
        self.store = store
        settings = store.load()
        now = clock.now
        lastTick = clock.now
    }

    func startRealTimeTicking() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        timer?.tolerance = 0.2
    }

    // MARK: Derived state

    var due: Set<BreakKind> { scheduler.due(settings) }

    var suppressionReasons: [SuppressionReason] {
        var reasons: [SuppressionReason] = presentationMode ? [.presentationMode] : []
        reasons += simulatedSignals.map(SuppressionReason.simulated)
        return reasons.sorted()
    }

    var isWorkingTime: Bool { settings.isWorkingTime(now) }

    // MARK: Tick

    func tick() {
        let current = clock.now
        let elapsed = current.timeIntervalSince(lastTick)
        lastTick = current
        now = current
        guard elapsed > 0 else { return }
        guard elapsed <= Self.maxTickGap else {
            onEvent("gap", ["seconds": elapsed])
            return
        }

        if let until = pausedUntil, current >= until {
            pausedUntil = nil
            onEvent("pauseEnded", [:])
        }
        if presentationMode, let until = presentationUntil, current >= until {
            setPresentationMode(false)
        }
        if let active = activeBreak {
            if current >= active.endsAt { finishBreak(active) }
            return
        }
        guard pausedUntil == nil, isWorkingTime else { return }

        scheduler.accumulate(elapsed)
        let due = self.due
        let suppressed = !suppressionReasons.isEmpty
        if suppressed && !due.isEmpty { deferredWhileDue = true }
        if let kinds = coordinator.evaluate(now: current, due: due, suppressed: suppressed, settings: settings) {
            remindersDelivered += 1
            onEvent("reminder", ["kinds": kinds.sorted().map(\.rawValue), "catchUp": deferredWhileDue])
            sink?.remind(kinds, catchUp: deferredWhileDue)
            deferredWhileDue = false
        }
    }

    // MARK: Actions

    func startBreak(_ kinds: Set<BreakKind>) {
        guard !kinds.isEmpty, activeBreak == nil else { return }
        let length = kinds.map(settings.duration).max() ?? 0
        activeBreak = ActiveBreak(kinds: kinds, endsAt: now.addingTimeInterval(length))
        sink?.clearReminders()
        onEvent("breakStarted", ["kinds": kinds.sorted().map(\.rawValue), "seconds": length])
    }

    /// "Start break" from a reminder: whatever is due, or an eye break if nothing is.
    func startDueBreak() {
        startBreak(due.isEmpty ? [.eye] : due)
    }

    func endBreakEarly() {
        guard let active = activeBreak else { return }
        activeBreak = nil
        onEvent("breakSkipped", ["kinds": active.kinds.sorted().map(\.rawValue)])
    }

    private func finishBreak(_ active: ActiveBreak) {
        activeBreak = nil
        scheduler.reset(active.kinds)
        coordinator.credit(active.kinds)
        onEvent("breakCompleted", ["kinds": active.kinds.sorted().map(\.rawValue)])
        sink?.breakFinished(active.kinds)
    }

    /// "Already took a break": credits only the chosen types.
    func credit(_ kinds: Set<BreakKind>) {
        guard !kinds.isEmpty else { return }
        scheduler.reset(kinds)
        coordinator.credit(kinds)
        sink?.clearReminders()
        onEvent("credited", ["kinds": kinds.sorted().map(\.rawValue)])
    }

    func creditDue() { credit(due) }

    func snooze() {
        coordinator.snooze(now: now, settings: settings)
        sink?.clearReminders()
        onEvent("snoozed", ["minutes": settings.snoozeMinutes])
    }

    func pause(minutes: Double) { pause(until: now.addingTimeInterval(minutes * 60)) }

    func pauseUntilTomorrow() {
        let calendar = Calendar.current
        pause(until: calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!))
    }

    private func pause(until date: Date) {
        pausedUntil = date
        sink?.clearReminders()
        onEvent("paused", ["until": date.timeIntervalSince1970])
    }

    func resume() {
        guard pausedUntil != nil else { return }
        pausedUntil = nil
        onEvent("resumed", [:])
    }

    func setPresentationMode(_ on: Bool, minutes: Double? = nil) {
        presentationMode = on
        presentationUntil = on ? minutes.map { now.addingTimeInterval($0 * 60) } : nil
        if on { sink?.clearReminders() }
        suppressionChanged()
        onEvent(on ? "presentationStarted" : "presentationEnded", minutes.map { ["minutes": $0] } ?? [:])
    }

    func setSimulatedSignal(_ name: String, active: Bool) {
        if active { simulatedSignals.insert(name) } else { simulatedSignals.remove(name) }
        suppressionChanged()
        onEvent("signal", ["name": name, "active": active])
    }

    private func suppressionChanged() {
        coordinator.updateSuppression(!suppressionReasons.isEmpty, now: now, settings: settings)
    }

    func updateSettings(_ change: (inout BreakSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        store.save(next)
        onEvent("settingsChanged", [:])
    }
}
