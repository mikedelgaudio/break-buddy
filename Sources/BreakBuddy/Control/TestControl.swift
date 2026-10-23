import AppKit

/// E2E test mode, enabled only by `BB_TEST_MODE=1`. The clock becomes manual, reminders are
/// recorded instead of posted, and the app obeys `BreakBuddy ctl …` commands sent as
/// distributed notifications scoped to its state directory. After each command it writes
/// `state.json`; every model event is appended to `events.jsonl`.
struct TestConfig {
    static let notificationName = Notification.Name("dev.delgaudio.breakbuddy.ctl")
    static let defaultStart = "2026-10-26T09:00:00" // a Monday, at the start of working hours

    let stateDir: URL
    let start: Date

    static func fromEnvironment() -> TestConfig? {
        let env = ProcessInfo.processInfo.environment
        guard env["BB_TEST_MODE"] == "1", let dir = env["BB_STATE_DIR"],
              let start = parseLocal(env["BB_TEST_START"] ?? defaultStart)
        else { return nil }
        return TestConfig(stateDir: URL(filePath: dir), start: start)
    }

    static func parseLocal(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: text)
    }

    static func formatLocal(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }
}

final class TestControl: ReminderSink {
    private struct CommandError: Error { let message: String }

    private let model: AppModel
    private let clock: ManualClock
    private let config: TestConfig
    private var observer: NSObjectProtocol?

    init(model: AppModel, config: TestConfig) {
        self.model = model
        self.clock = model.clock as! ManualClock
        self.config = config
        model.onEvent = { [weak self] name, data in self?.record(name, data) }
    }

    func start() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: TestConfig.notificationName, object: config.stateDir.path, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String, let cmd = note.userInfo?["cmd"] as? String else { return }
            let args = note.userInfo?["args"] as? [String] ?? []
            MainActor.assumeIsolated { self?.receive(id: id, cmd: cmd, args: args) }
        }
        record("launched", [:])
        writeState(cmdId: "launch", error: nil)
    }

    // Reminders are captured through model events; nothing is posted in test mode.
    func remind(_ kinds: Set<BreakKind>, catchUp: Bool) {}
    func breakFinished(_ kinds: Set<BreakKind>) {}
    func clearReminders() {}

    private func receive(id: String, cmd: String, args: [String]) {
        do {
            try run(cmd, args)
            writeState(cmdId: id, error: nil)
        } catch let error as CommandError {
            writeState(cmdId: id, error: error.message)
        } catch {
            writeState(cmdId: id, error: "\(error)")
        }
        if cmd == "quit" { NSApp.terminate(nil) }
    }

    private func run(_ cmd: String, _ args: [String]) throws {
        func arg(_ i: Int) throws -> String {
            guard i < args.count else { throw CommandError(message: "\(cmd): missing argument \(i + 1)") }
            return args[i]
        }
        func kinds(_ text: String) throws -> Set<BreakKind> {
            switch text {
            case "eye": return [.eye]
            case "move": return [.move]
            case "both": return [.eye, .move]
            default: throw CommandError(message: "unknown break kind \(text)")
            }
        }
        func onOff(_ text: String) throws -> Bool {
            guard text == "on" || text == "off" else { throw CommandError(message: "expected on/off, got \(text)") }
            return text == "on"
        }

        switch cmd {
        case "state", "quit":
            break
        case "advance":
            guard let seconds = Int(try arg(0)), seconds >= 0 else { throw CommandError(message: "advance needs whole seconds") }
            for _ in 0..<seconds {
                clock.now = clock.now.addingTimeInterval(1)
                model.tick()
            }
        case "set-time":
            guard let date = TestConfig.parseLocal(try arg(0)) else { throw CommandError(message: "bad time \(args[0])") }
            clock.now = date
            model.tick()
        case "presentation":
            model.setPresentationMode(try onOff(arg(0)), minutes: args.count > 1 ? Double(args[1]) : nil)
        case "signal":
            model.setSimulatedSignal(try arg(0), active: try onOff(arg(1)))
        case "pause":
            let value = try arg(0)
            if value == "tomorrow" {
                model.pauseUntilTomorrow()
            } else if let minutes = Double(value) {
                model.pause(minutes: minutes)
            } else {
                throw CommandError(message: "pause needs minutes or 'tomorrow'")
            }
        case "resume":
            model.resume()
        case "take":
            model.startBreak(try kinds(arg(0)))
        case "end-break":
            model.endBreakEarly()
        case "credit":
            let value = try arg(0)
            if value == "due" { model.creditDue() } else { model.credit(try kinds(value)) }
        case "snooze":
            model.snooze()
        case "settings":
            guard let data = try arg(0).data(using: .utf8),
                  let patch = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw CommandError(message: "settings needs a JSON object") }
            let next = try model.settings.merging(patch)
            model.updateSettings { $0 = next }
        default:
            throw CommandError(message: "unknown command \(cmd)")
        }
    }

    // MARK: Output

    private var elapsed: Double { clock.now.timeIntervalSince(config.start) }

    private func record(_ event: String, _ data: [String: Any]) {
        var line = data
        line["event"] = event
        line["t"] = elapsed
        line["at"] = TestConfig.formatLocal(clock.now)
        append(line, to: config.stateDir.appending(path: "events.jsonl"))
    }

    private func writeState(cmdId: String, error: String?) {
        let m = model
        var state: [String: Any] = [
            "cmdId": cmdId,
            "at": TestConfig.formatLocal(clock.now),
            "t": elapsed,
            "status": m.statusText,
            "menuBar": [m.menuBarSymbol, m.menuBarText],
            "worked": Dictionary(uniqueKeysWithValues: BreakKind.allCases.map { ($0.rawValue, m.scheduler.workedSeconds($0)) }),
            "due": m.due.sorted().map(\.rawValue),
            "suppression": m.suppressionReasons.map(\.label),
            "paused": m.pausedUntil != nil,
            "presentationMode": m.presentationMode,
            "graceActive": m.coordinator.graceEndsAt != nil,
            "snoozed": m.coordinator.snoozedUntil != nil,
            "isWorkingTime": m.isWorkingTime,
            "remindersDelivered": m.remindersDelivered,
            "settings": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(m.settings))) ?? [:],
        ]
        if let active = m.activeBreak {
            state["activeBreak"] = ["kinds": active.kinds.sorted().map(\.rawValue), "secondsLeft": active.endsAt.timeIntervalSince(clock.now)]
        }
        if let error { state["error"] = error }
        let url = config.stateDir.appending(path: "state.json")
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func append(_ object: [String: Any], to url: URL) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

/// `BreakBuddy ctl <command> [args…]`: sends one command to the test-mode app sharing
/// `BB_STATE_DIR`, waits for its acknowledgement, and prints the resulting state JSON.
enum ControlClient {
    static func run(_ args: [String]) -> Int32 {
        guard let dir = ProcessInfo.processInfo.environment["BB_STATE_DIR"], let cmd = args.first else {
            FileHandle.standardError.write(Data("usage: BB_STATE_DIR=… BreakBuddy ctl <command> [args…]\n".utf8))
            return 2
        }
        let id = UUID().uuidString
        DistributedNotificationCenter.default().postNotificationName(
            TestConfig.notificationName, object: dir,
            userInfo: ["id": id, "cmd": cmd, "args": Array(args.dropFirst())], deliverImmediately: true
        )
        let stateURL = URL(filePath: dir).appending(path: "state.json")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let data = try? Data(contentsOf: stateURL),
               let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               state["cmdId"] as? String == id {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
                return state["error"] == nil ? 0 : 1
            }
            usleep(10_000)
        }
        FileHandle.standardError.write(Data("ctl: no acknowledgement for '\(cmd)' within 15s\n".utf8))
        return 3
    }
}
