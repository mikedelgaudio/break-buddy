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
}
