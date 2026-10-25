import UserNotifications

/// Delivers reminders as native notifications. One identifier is reused so a new
/// reminder replaces the old one instead of stacking.
final class NotificationSink: NSObject, ReminderSink, UNUserNotificationCenterDelegate {
    private static let reminderID = "break-due"
    private static let category = "BREAK_DUE"
    private enum Action: String { case start = "START", snooze = "SNOOZE", credit = "CREDIT" }

    private let model: AppModel
    private let center = UNUserNotificationCenter.current()

    init(model: AppModel) {
        self.model = model
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [
                UNNotificationAction(identifier: Action.start.rawValue, title: "Start break", options: []),
                UNNotificationAction(identifier: Action.snooze.rawValue, title: "Snooze", options: []),
                UNNotificationAction(identifier: Action.credit.rawValue, title: "Already took a break", options: []),
            ], intentIdentifiers: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func remind(_ kinds: Set<BreakKind>, catchUp: Bool) {
        guard !model.usesOverlay else { return }
        let content = UNMutableNotificationContent()
        switch (catchUp, kinds) {
        case (true, _):
            content.title = "Your meeting is over"
            content.body = kinds.contains(.move)
                ? "Take a moment to stand, move, and rest your eyes."
                : "Take a moment to rest your eyes."
        case (false, [.eye]):
            content.title = "Eye break"
            content.body = "Look at something far away for \(Int(model.settings.eyeDurationSeconds)) seconds."
        case (false, [.move]):
            content.title = "Movement break"
            content.body = "Stand up and move for a couple of minutes."
        default:
            content.title = "Time for a break"
            content.body = "Stand, move, and rest your eyes."
        }
        content.categoryIdentifier = Self.category
        content.sound = .default
        center.add(UNNotificationRequest(identifier: Self.reminderID, content: content, trigger: nil))
    }

    func breakFinished(_ kinds: Set<BreakKind>) {
        guard !model.usesOverlay else { return }
        let content = UNMutableNotificationContent()
        content.title = "Break complete"
        content.body = "Timers restarted for \(kinds.sorted().map { $0.label.lowercased() }.joined(separator: " and "))."
        center.add(UNNotificationRequest(identifier: Self.reminderID, content: content, trigger: nil))
    }

    func clearReminders() {
        center.removeDeliveredNotifications(withIdentifiers: [Self.reminderID])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = Action(rawValue: response.actionIdentifier)
        Task { @MainActor in
            switch action {
            case .start: self.model.startDueBreak()
            case .snooze: self.model.snooze()
            case .credit: self.model.creditDue()
            case nil: break
            }
        }
        completionHandler()
    }
}
