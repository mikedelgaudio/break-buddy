import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 2, args[1] == "ctl" {
            exit(ControlClient.run(Array(args.dropFirst(2))))
        }
        if args.count >= 3, args[1] == "probe", args[2] == "--watch" {
            DetectionProbe.watch()
        }
        if args.count >= 2, args[1] == "probe" {
            exit(DetectionProbe.run(samples: args.count >= 3 ? Int(args[2]) ?? 5 : 5))
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
        Image(nsImage: MenuBarIcon.image(symbol: model.menuBarSymbol, text: model.menuBarText))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private var sink: ReminderSink?
    private var control: TestControl?
    private var systemEvents: SystemEvents?
    private(set) var overlay: BreakOverlayController?
    private var activity: NSObjectProtocol?

    override init() {
        if let config = TestConfig.fromEnvironment() {
            model = AppModel(clock: ManualClock(start: config.start),
                             store: SettingsStore(url: config.stateDir.appending(path: "settings.json")),
                             snapshots: SnapshotStore(url: config.stateDir.appending(path: "timers.json")))
            super.init()
            let control = TestControl(model: model, config: config)
            self.control = control
            sink = control
            model.detector = control.detector
            model.inputMonitor = control.input
            model.videoMonitor = control.video
        } else {
            let support = URL.applicationSupportDirectory.appending(path: "BreakBuddy")
            model = AppModel(clock: SystemClock(),
                             store: SettingsStore(url: support.appending(path: "settings.json")),
                             snapshots: SnapshotStore(url: support.appending(path: "timers.json")))
            super.init()
            sink = NotificationSink(model: model)
            model.detector = CoreAudioDetector()
            model.inputMonitor = HardwareInputMonitor()
            model.videoMonitor = PowerAssertionVideoMonitor()
        }
        model.sink = sink
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.restoreSavedState()
        if let control {
            // Real overlay windows only when a scenario asks for them, so local E2E runs
            // don't flash full-screen windows over your work.
            if ProcessInfo.processInfo.environment["BB_TEST_OVERLAY_WINDOWS"] == "1" {
                overlay = BreakOverlayController(model: model)
                control.overlay = overlay
            }
            control.start()
        } else {
            systemEvents = SystemEvents(model: model)
            overlay = BreakOverlayController(model: model)
            // Menu-bar apps get App Nap'd; keep the 1s tick honest without blocking sleep.
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Break timers")
            model.startRealTimeTicking()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.persist()
    }
}
