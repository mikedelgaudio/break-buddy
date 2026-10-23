import AppKit

/// Forwards macOS sleep, display sleep, screen lock and fast-user-switching to the model.
final class SystemEvents {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []

    init(model: AppModel) {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let events: [(NotificationCenter, Notification.Name, AwayReason, Bool)] = [
            (workspace, NSWorkspace.willSleepNotification, .asleep, true),
            (workspace, NSWorkspace.didWakeNotification, .asleep, false),
            (workspace, NSWorkspace.screensDidSleepNotification, .displaysAsleep, true),
            (workspace, NSWorkspace.screensDidWakeNotification, .displaysAsleep, false),
            (workspace, NSWorkspace.sessionDidResignActiveNotification, .switchedOut, true),
            (workspace, NSWorkspace.sessionDidBecomeActiveNotification, .switchedOut, false),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .locked, true),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .locked, false),
        ]
        for (center, name, reason, began) in events {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    // Bring the clock current first so away time is measured from the real moment.
                    model.tick()
                    if began {
                        model.awayBegan(reason)
                        model.persist()
                    } else {
                        model.awayEnded(reason)
                    }
                }
            }
            tokens.append((center, token))
        }
    }

    isolated deinit {
        for (center, token) in tokens { center.removeObserver(token) }
    }
}
