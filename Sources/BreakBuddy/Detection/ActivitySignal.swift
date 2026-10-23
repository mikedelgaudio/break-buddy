import Foundation

/// One piece of evidence that a call may be underway. Labels state only what was observed
/// ("Microsoft Teams using microphone"), never an inferred "Teams meeting".
struct ActivitySignal: Hashable, Comparable {
    enum Kind: String { case microphone, camera }

    var kind: Kind
    /// App-level bundle ID when the source is known (helper processes map to their parent app).
    var appID: String?
    var appName: String?

    var label: String {
        switch kind {
        case .microphone: appName.map { "\($0) using microphone" } ?? "Microphone in use"
        case .camera: "Camera in use"
        }
    }

    static func < (a: ActivitySignal, b: ActivitySignal) -> Bool { a.label < b.label }
}

/// A raw, undebounced reading. A non-nil error means detection is currently unavailable.
struct DetectionReading {
    var signals: Set<ActivitySignal> = []
    var error: String?
}

protocol ActivityDetector: AnyObject {
    func read() -> DetectionReading
}

/// Stands in for Core Audio under E2E; the harness sets what it "sees".
final class FakeDetector: ActivityDetector {
    var signals: Set<ActivitySignal> = []
    var error: String?

    func read() -> DetectionReading { DetectionReading(signals: signals, error: error) }
}
