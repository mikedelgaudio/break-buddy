import AppKit

enum AppIdentity {
    /// Maps a process to its app: helper processes (e.g. `com.google.Chrome.helper`) resolve
    /// to the parent app's bundle ID and name.
    static func identify(pid: pid_t, bundleID: String?) -> (id: String?, name: String?) {
        var appID = bundleID.flatMap { $0.isEmpty ? nil : $0 }
        if let id = appID, let range = id.range(of: ".helper", options: .caseInsensitive) {
            appID = String(id[..<range.lowerBound])
        }
        if let id = appID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            return (id, app.localizedName ?? id)
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            return (appID ?? app.bundleIdentifier, app.localizedName ?? appID)
        }
        var buffer = [CChar](repeating: 0, count: 256)
        let name = proc_name(pid, &buffer, UInt32(buffer.count)) > 0
            ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : nil
        return (appID, name ?? appID)
    }
}
