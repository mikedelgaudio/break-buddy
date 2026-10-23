import Foundation

/// `BreakBuddy probe [samples]`: reads the real detector a few times and prints JSON with
/// what it saw and how long each read took. Used by the E2E hardware check and for
/// diagnosing detection on a new Mac or Teams version.
enum DetectionProbe {
    static func run(samples: Int) -> Int32 {
        let detector = CoreAudioDetector()
        var timings: [Double] = []
        var reading = DetectionReading()
        for _ in 0..<max(1, samples) {
            let start = DispatchTime.now()
            reading = detector.read()
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        }
        let output: [String: Any] = [
            "available": reading.error == nil,
            "error": reading.error as Any? ?? NSNull(),
            "signals": reading.signals.sorted().map { ["kind": $0.kind.rawValue, "appID": $0.appID as Any? ?? NSNull(), "appName": $0.appName as Any? ?? NSNull(), "label": $0.label] },
            "timingsMs": timings,
        ]
        let data = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data + Data("\n".utf8))
        return reading.error == nil ? 0 : 1
    }

    /// `BreakBuddy probe --watch`: polls twice a second and prints one timestamped line each
    /// time the evidence, detector availability, or set of apps playing audio changes. Raw
    /// readings, no debounce, so short blips and mute gaps are visible. Runs until Ctrl-C.
    static func watch() -> Never {
        let detector = CoreAudioDetector()
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss.S"
        var lastSignals: Set<ActivitySignal> = []
        var lastError: String?
        var lastOutput: Set<String> = []
        var first = true
        func emit(_ text: String) { FileHandle.standardOutput.write(Data("\(clock.string(from: Date()))  \(text)\n".utf8)) }

        emit("watching (raw readings, polled every 0.5s; Ctrl-C to stop)")
        while true {
            let reading = detector.read()
            let output = detector.audioOutputApps()
            if first || reading.signals != lastSignals || reading.error != lastError || output != lastOutput {
                var changes: [String] = []
                changes += reading.signals.subtracting(lastSignals).sorted().map { "+ \($0.label)" }
                changes += lastSignals.subtracting(reading.signals).sorted().map { "- \($0.label)" }
                if reading.error != lastError { changes.append(reading.error.map { "! \($0)" } ?? "! detector OK") }
                if output != lastOutput { changes.append("audio out: \(output.isEmpty ? "none" : output.sorted().joined(separator: ", "))") }
                let active = reading.signals.isEmpty ? "none" : reading.signals.sorted().map(\.label).joined(separator: ", ")
                emit("\(changes.isEmpty ? "initial" : changes.joined(separator: "; "))  |  evidence: \(active)")
                lastSignals = reading.signals
                lastError = reading.error
                lastOutput = output
                first = false
            }
            // Pump the run loop so NSRunningApplication sees apps launched after we started.
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        }
    }
}
