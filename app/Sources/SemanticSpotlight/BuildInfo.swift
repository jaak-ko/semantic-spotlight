import Foundation

/// The build stamp: version, short commit (with "-dirty" when the tree had uncommitted changes), and build date. build.sh
/// writes them into the built app's Info.plist (CFBundleVersion = "0.1.0+<commit>", SSBuildDate).
enum BuildInfo {
    static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    static var version: String { info["CFBundleShortVersionString"] as? String ?? "?" }

    /// The commit part of CFBundleVersion, or "unknown" for a build without a stamp.
    static var commit: String {
        let full = info["CFBundleVersion"] as? String ?? ""
        guard let plus = full.firstIndex(of: "+") else { return "unknown" }
        return String(full[full.index(after: plus)...])
    }

    static var date: String { info["SSBuildDate"] as? String ?? "unknown date" }

    /// "Version 0.1.0 (f1ae890), built 14 Nov 2026"
    static var line: String { "Version \(version) (\(commit)), built \(date)" }

    /// The short form for the menu's last line, which sets the menu's width: "0.1.0 · f1ae890 · 14 Nov 2026".
    static var menuLine: String { "\(version) · \(commit) · \(date)" }
}
