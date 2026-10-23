import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 2, args[1] == "ctl" {
            exit(ControlClient.run(Array(args.dropFirst(2))))
        }
        BreakBuddyApp.main()
    }
}

struct BreakBuddyApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        let text = model.menuBarText
        if text.isEmpty {
            Image(systemName: model.menuBarSymbol)
        } else {
            Label(text, systemImage: model.menuBarSymbol).labelStyle(.titleAndIcon)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var sink: ReminderSink?
    private var control: TestControl?
    private var activity: NSObjectProtocol?

    override init() {
        if let config = TestConfig.fromEnvironment() {
            model = AppModel(clock: ManualClock(start: config.start), store: SettingsStore(url: config.stateDir.appending(path: "settings.json")))
            super.init()
            let control = TestControl(model: model, config: config)
            self.control = control
            sink = control
        } else {
            let support = URL.applicationSupportDirectory.appending(path: "BreakBuddy")
            model = AppModel(clock: SystemClock(), store: SettingsStore(url: support.appending(path: "settings.json")))
            super.init()
            sink = NotificationSink(model: model)
            // Menu-bar apps get App Nap'd; keep the 1s tick honest without blocking sleep.
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Break timers")
            model.startRealTimeTicking()
        }
        model.sink = sink
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        control?.start()
    }
}
