import Foundation
import Observation

struct ActiveBreak: Equatable {
    var kinds: Set<BreakKind>
    var endsAt: Date
}

/// Reasons the user is known to be away from the screen. Work time stops while any is active.
enum AwayReason: String, CaseIterable, Comparable {
    case locked, asleep, displaysAsleep, switchedOut, idle

    var label: String {
        switch self {
        case .idle: "No input from you"
        case .locked: "Screen locked"
        case .asleep: "Asleep"
        case .displaysAsleep: "Displays asleep"
        case .switchedOut: "Switched user"
        }
    }

    static func < (a: AwayReason, b: AwayReason) -> Bool { a.rawValue < b.rawValue }
}

protocol ReminderSink: AnyObject {
    func remind(_ kinds: Set<BreakKind>, catchUp: Bool)
    func breakFinished(_ kinds: Set<BreakKind>)
    func clearReminders()
}

/// Owns the timers and every user action. The menu, notifications, system events and the
/// E2E control channel all drive the app through these same methods.
@Observable
final class AppModel {
    /// A tick further apart than this means sleep or a clock change: reconcile, don't replay.
    static let maxTickGap: TimeInterval = 15
    /// How often timer state is written to disk while ticking (actions save immediately).
    static let persistInterval: TimeInterval = 15
    /// After this long not running (or on a new day) a relaunch starts with fresh timers.
    static let restartResetAfter: TimeInterval = 30 * 60
    /// Detection: poll cadence, how long evidence must persist to count (filters blips), how
    /// long it may vanish before a call is considered over (rides out mute/unmute), and how
    /// long evidence is held while detection is failing.
    static let pollInterval: TimeInterval = 2
    static let onsetDelay: TimeInterval = 5
    static let releaseDelay: TimeInterval = 10
    static let holdOnFailure: TimeInterval = 5 * 60
    /// Keep-awake utilities hold display assertions too; they don't mean anyone is watching.
    static let keepAwakeTools: Set<String> = ["caffeinate", "Amphetamine", "KeepingYouAwake", "Caffeine", "Lungo", "Theine"]

    private(set) var settings: BreakSettings
    private(set) var now: Date
    private(set) var scheduler = BreakScheduler()
    private(set) var coordinator = ReminderCoordinator()
    private(set) var presentationMode = false
    private(set) var presentationUntil: Date?
    private(set) var simulatedSignals: Set<String> = []
    private(set) var pausedUntil: Date?
    private(set) var activeBreak: ActiveBreak?
    private(set) var awayReasons: Set<AwayReason> = []
    private(set) var remindersDelivered = 0
    /// Debounced detector evidence currently deferring reminders.
    private(set) var detectedSignals: [ActivitySignal] = []
    private(set) var detectionError: String?
    /// Apps seen using the microphone this session (bundle ID → name), for the ignore list UI.
    private(set) var seenMicApps: [String: String] = [:]
    /// Apps playing video (holding the display awake): screen time even without input.
    private(set) var watchingApps: [String] = []

    @ObservationIgnored let clock: AppClock
    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private let snapshots: SnapshotStore
    @ObservationIgnored weak var sink: ReminderSink?
    @ObservationIgnored var detector: ActivityDetector?
    @ObservationIgnored var inputMonitor: InputMonitor?
    @ObservationIgnored var videoMonitor: VideoMonitor?
    /// Last moment a meeting or video vouched for the person being at the screen.
    @ObservationIgnored private var lastPresenceHold = Date.distantPast
    /// Work counted since the person's last input; refunded if that stretch turns out to be idle.
    @ObservationIgnored private var workSinceInput: TimeInterval = 0
    @ObservationIgnored private var lastPoll = Date.distantPast
    @ObservationIgnored private var lastGoodReading: Date?
    @ObservationIgnored private var firstSeen: [ActivitySignal: Date] = [:]
    @ObservationIgnored private var lastSeen: [ActivitySignal: Date] = [:]
    @ObservationIgnored var onEvent: (String, [String: Any]) -> Void = { _, _ in }
    @ObservationIgnored private var lastTick: Date
    @ObservationIgnored private var lastPersist: Date
    @ObservationIgnored private var awaySince: Date?
    @ObservationIgnored private var deferredWhileDue = false
    @ObservationIgnored private var timer: Timer?

    init(clock: AppClock, store: SettingsStore, snapshots: SnapshotStore) {
        self.clock = clock
        self.store = store
        self.snapshots = snapshots
        settings = store.load()
        now = clock.now
        lastTick = clock.now
        lastPersist = clock.now
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
        reasons += detectedSignals.map(SuppressionReason.detected)
        reasons += simulatedSignals.map(SuppressionReason.simulated)
        return reasons.sorted()
    }

    var isAway: Bool { !awayReasons.isEmpty }

    /// Away counts as suppression too, so returning gets the same grace period as a meeting ending.
    private var isSuppressed: Bool { isAway || !suppressionReasons.isEmpty }

    var isWorkingTime: Bool { settings.isWorkingTime(now) }

    // MARK: Tick

    func tick() {
        let current = clock.now
        let elapsed = current.timeIntervalSince(lastTick)
        lastTick = current
        now = current
        pollDetection()
        guard elapsed > 0 else { return }
        guard elapsed <= Self.maxTickGap else {
            emit("gap", ["seconds": elapsed])
            return
        }

        if let until = pausedUntil, current >= until {
            pausedUntil = nil
            emit("pauseEnded", [:])
        }
        if presentationMode, let until = presentationUntil, current >= until {
            setPresentationMode(false)
        }
        if current.timeIntervalSince(lastPersist) >= Self.persistInterval { persist() }
        if let active = activeBreak {
            if current >= active.endsAt { finishBreak(active) }
            return
        }
        let working = pausedUntil == nil && !isAway && isWorkingTime
        if working { scheduler.accumulate(elapsed) }
        checkIdle(accumulated: working ? elapsed : 0)
        guard working, !isAway else { return }

        let due = self.due
        let suppressed = isSuppressed
        if suppressed && !due.isEmpty { deferredWhileDue = true }
        if let kinds = coordinator.evaluate(now: current, due: due, suppressed: suppressed, settings: settings) {
            remindersDelivered += 1
            emit("reminder", ["kinds": kinds.sorted().map(\.rawValue), "catchUp": deferredWhileDue])
            sink?.remind(kinds, catchUp: deferredWhileDue)
            deferredWhileDue = false
        }
    }

    // MARK: Detection

    private func pollDetection() {
        guard now.timeIntervalSince(lastPoll) >= Self.pollInterval else { return }
        lastPoll = now
        if let detector { ingest(detector.read()) }
        if let videoMonitor {
            let apps = Array(Set(videoMonitor.displaySleepHolders()).subtracting(Self.keepAwakeTools)).sorted()
            if apps != watchingApps {
                watchingApps = apps
                emit("watching", ["apps": apps])
            }
        }
    }

    /// Debounces raw readings into evidence. A signal must be seen across `onsetDelay` to
    /// count, and stays until it has been absent for `releaseDelay`.
    func ingest(_ reading: DetectionReading) {
        if let error = reading.error {
            if detectionError == nil { emit("detectionUnavailable", ["error": error]) }
            detectionError = error
            // A failing detector is not evidence the call ended: hold what we had, for a while.
            if let good = lastGoodReading, now.timeIntervalSince(good) < Self.holdOnFailure {
                for signal in detectedSignals { lastSeen[signal] = now }
            }
        } else {
            if detectionError != nil { emit("detectionRestored", [:]) }
            detectionError = nil
            lastGoodReading = now
            for signal in reading.signals {
                if signal.kind == .microphone, let id = signal.appID { seenMicApps[id] = signal.appName ?? id }
                guard counts(signal) else { continue }
                if firstSeen[signal] == nil { firstSeen[signal] = now }
                lastSeen[signal] = now
            }
        }
        for (signal, seen) in lastSeen where now.timeIntervalSince(seen) > Self.releaseDelay {
            lastSeen[signal] = nil
            firstSeen[signal] = nil
        }
        let confirmed = Set(detectedSignals).filter { lastSeen[$0] != nil }
            .union(firstSeen.filter { signal, first in (lastSeen[signal] ?? first).timeIntervalSince(first) >= Self.onsetDelay }.keys)
        let active = confirmed.sorted()
        guard active != detectedSignals else { return }
        detectedSignals = active
        suppressionChanged()
        emit("detection", ["active": active.map(\.label)])
    }

    private func counts(_ signal: ActivitySignal) -> Bool {
        switch signal.kind {
        case .microphone: settings.detectMicrophone && !(signal.appID.map(settings.ignoredApps.contains) ?? false)
        case .camera: settings.detectCamera
        }
    }

    // MARK: Idle (no input from the person)

    /// Hardware input stopping for `idleMinutes` means the person stepped away, even if agents
    /// keep the Mac awake. During a meeting, presentation or video, no input just means
    /// watching, so idle is measured from whichever came last: input or the end of that.
    /// Away time is backdated to that moment and the work counted since is refunded.
    private func checkIdle(accumulated: TimeInterval) {
        guard let inputMonitor else { return }
        if !suppressionReasons.isEmpty || !watchingApps.isEmpty { lastPresenceHold = now }
        let idle = min(inputMonitor.secondsSinceHumanInput(now: now), max(0, now.timeIntervalSince(lastPresenceHold)))
        // Work since the last sign of presence can't exceed the time since it.
        workSinceInput = min(workSinceInput + accumulated, idle)

        let threshold = settings.idleMinutes * 60
        if awayReasons.contains(.idle) {
            if idle < threshold { awayEnded(.idle) }
        } else if idle >= threshold, !isAway {
            scheduler.refund(workSinceInput)
            workSinceInput = 0
            awayBegan(.idle, since: now.addingTimeInterval(-idle))
        }
    }

    // MARK: Away (lock, sleep, idle)

    func awayBegan(_ reason: AwayReason, since: Date? = nil) {
        guard !awayReasons.contains(reason) else { return }
        if awayReasons.isEmpty { awaySince = since ?? now }
        awayReasons.insert(reason)
        suppressionChanged()
        emit("awayBegan", ["reason": reason.rawValue])
    }

    /// When the last away reason clears, time away credits each break type whose duration
    /// it covered (if enabled). Locked or asleep is evidence of being away; idle input is not.
    func awayEnded(_ reason: AwayReason) {
        guard awayReasons.remove(reason) != nil else { return }
        guard awayReasons.isEmpty, let since = awaySince else {
            emit("awayEnded", ["reason": reason.rawValue])
            return
        }
        awaySince = nil
        let seconds = max(0, now.timeIntervalSince(since))
        let credited = settings.creditTimeAway
            ? Set(BreakKind.allCases.filter { seconds >= settings.duration($0) })
            : []
        scheduler.reset(credited)
        coordinator.credit(credited)
        if !credited.isEmpty { sink?.clearReminders() }
        suppressionChanged()
        emit("returned", ["reason": reason.rawValue, "seconds": seconds, "credited": credited.sorted().map(\.rawValue)])
    }

    // MARK: Actions

    func startBreak(_ kinds: Set<BreakKind>) {
        guard !kinds.isEmpty, activeBreak == nil else { return }
        let length = kinds.map(settings.duration).max() ?? 0
        activeBreak = ActiveBreak(kinds: kinds, endsAt: now.addingTimeInterval(length))
        sink?.clearReminders()
        emit("breakStarted", ["kinds": kinds.sorted().map(\.rawValue), "seconds": length])
    }

    /// "Start break" from a reminder: whatever is due, or an eye break if nothing is.
    func startDueBreak() {
        startBreak(due.isEmpty ? [.eye] : due)
    }

    func endBreakEarly() {
        guard let active = activeBreak else { return }
        activeBreak = nil
        emit("breakSkipped", ["kinds": active.kinds.sorted().map(\.rawValue)])
    }

    private func finishBreak(_ active: ActiveBreak) {
        activeBreak = nil
        scheduler.reset(active.kinds)
        coordinator.credit(active.kinds)
        emit("breakCompleted", ["kinds": active.kinds.sorted().map(\.rawValue)])
        sink?.breakFinished(active.kinds)
    }

    /// "Already took a break": credits only the chosen types.
    func credit(_ kinds: Set<BreakKind>) {
        guard !kinds.isEmpty else { return }
        scheduler.reset(kinds)
        coordinator.credit(kinds)
        sink?.clearReminders()
        emit("credited", ["kinds": kinds.sorted().map(\.rawValue)])
    }

    func creditDue() { credit(due) }

    func snooze() {
        coordinator.snooze(now: now, settings: settings)
        sink?.clearReminders()
        emit("snoozed", ["minutes": settings.snoozeMinutes])
    }

    func pause(minutes: Double) { pause(until: now.addingTimeInterval(minutes * 60)) }

    func pauseUntilTomorrow() {
        let calendar = Calendar.current
        pause(until: calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now)!))
    }

    private func pause(until date: Date) {
        pausedUntil = date
        sink?.clearReminders()
        emit("paused", ["until": date.timeIntervalSince1970])
    }

    func resume() {
        guard pausedUntil != nil else { return }
        pausedUntil = nil
        emit("resumed", [:])
    }

    func setPresentationMode(_ on: Bool, minutes: Double? = nil) {
        presentationMode = on
        presentationUntil = on ? minutes.map { now.addingTimeInterval($0 * 60) } : nil
        if on { sink?.clearReminders() }
        suppressionChanged()
        emit(on ? "presentationStarted" : "presentationEnded", minutes.map { ["minutes": $0] } ?? [:])
    }

    func setSimulatedSignal(_ name: String, active: Bool) {
        if active { simulatedSignals.insert(name) } else { simulatedSignals.remove(name) }
        suppressionChanged()
        emit("signal", ["name": name, "active": active])
    }

    private func suppressionChanged() {
        coordinator.updateSuppression(isSuppressed, now: now, settings: settings)
    }

    func updateSettings(_ change: (inout BreakSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        store.save(next)
        emit("settingsChanged", [:])
    }

    // MARK: Persistence

    private func emit(_ event: String, _ data: [String: Any]) {
        onEvent(event, data)
        persist()
    }

    func persist() {
        lastPersist = now
        snapshots.save(TimerSnapshot(
            savedAt: now,
            worked: Dictionary(uniqueKeysWithValues: BreakKind.allCases.map { ($0.rawValue, scheduler.workedSeconds($0)) }),
            pausedUntil: pausedUntil,
            presentationMode: presentationMode,
            presentationUntil: presentationUntil,
            snoozedUntil: coordinator.snoozedUntil,
            activeBreak: activeBreak.map { .init(kinds: $0.kinds.sorted(), endsAt: $0.endsAt) }
        ))
    }

    /// Restores the last snapshot on launch. Time the app wasn't running is neither work nor
    /// a credited break; a long downtime or a new day simply starts fresh timers. Breaks
    /// already due wait out a grace period instead of firing the moment the app opens.
    func restoreSavedState() {
        guard let saved = snapshots.load() else { return }
        let downtime = now.timeIntervalSince(saved.savedAt)
        pausedUntil = saved.pausedUntil.flatMap { $0 > now ? $0 : nil }

        if downtime >= Self.restartResetAfter || !Calendar.current.isDate(saved.savedAt, inSameDayAs: now) {
            emit("restored", ["fresh": true, "downtime": downtime])
            return
        }

        if saved.presentationMode, saved.presentationUntil.map({ $0 > now }) ?? true {
            presentationMode = true
            presentationUntil = saved.presentationUntil
        }
        var worked: [BreakKind: TimeInterval] = [:]
        for kind in BreakKind.allCases { worked[kind] = saved.worked[kind.rawValue] ?? 0 }
        scheduler.restore(worked)
        if let snooze = saved.snoozedUntil, snooze > now { coordinator.restoreSnooze(until: snooze) }
        if let savedBreak = saved.activeBreak {
            let kinds = Set(savedBreak.kinds)
            if savedBreak.endsAt > now {
                activeBreak = ActiveBreak(kinds: kinds, endsAt: savedBreak.endsAt)
            } else {
                scheduler.reset(kinds)
                emit("breakCompleted", ["kinds": savedBreak.kinds.map(\.rawValue), "whileNotRunning": true])
            }
        }
        coordinator.updateSuppression(isSuppressed, now: now, settings: settings)
        if !isSuppressed && !due.isEmpty { coordinator.beginGrace(now: now, settings: settings) }
        emit("restored", ["fresh": false, "downtime": downtime])
    }
}
