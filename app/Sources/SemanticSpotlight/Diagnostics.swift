import AppKit
import ServiceManagement

/// Plain-text diagnostics for a support request. Nothing is sent anywhere: the user reads the text, then copies
/// or saves it. Everything is redacted by `Redact` before it is shown, so no file names, queries, snippets,
/// folder names or e-mail addresses appear in it.
enum Diagnostics {
    /// The last engine status and status line. Set on the main thread by AppDelegate.
    static var latestStatus: EngineStatus?
    static var engineMessage = "Starting engine…"

    /// Everything the text is made of. `render` is pure: the same input always gives the same text.
    struct Input {
        var generated: String
        var appVersion: String
        var macOS: String
        var chip: String
        var engine: String
        var status: EngineStatus?
        var config: [String: String]
        var loginItem: Bool
        var hotkey: String
        var logLines: [String]
        var home: String
    }

    static func render(_ d: Input) -> String {
        var lines = [
            "Semantic Spotlight diagnostics",
            "Generated: \(d.generated)",
            "App: \(d.appVersion)",
            "macOS: \(d.macOS)",
            "Chip: \(d.chip)",
            "Engine: \(d.engine)",
        ]
        if let s = d.status {
            lines += [
                "Model installed: \(s.modelReady ? "yes" : "no")",
                "Indexing: \(s.indexing ? "yes" : "no")",
                "Files: \(s.files), chunks: \(s.chunks), folders: \(s.folders.count)",
            ]
        } else {
            lines.append("Model installed, indexing, files: unknown (engine not running)")
        }
        for key in ["model", "ocr_languages", "min_similarity"] {
            lines.append("Config \(key): \(d.config[key] ?? "default")")
        }
        lines += [
            "Login item: \(d.loginItem ? "on" : "off")",
            "Hotkey: \(d.hotkey)",
            "",
            "Engine log, last \(d.logLines.count) lines (redacted):",
        ]
        lines += d.logLines
        return Redact.text(lines.joined(separator: "\n"), home: d.home) + "\n"
    }

    /// The text of the uninstall report: what was removed, what could not be removed and why, and what is left.
    /// How many items each list of the uninstall report shows before "… and N more". Test runs may lower it through
    /// SS_TEST_REPORT_CAP, which the test gate ignores outside test mode.
    static var listCap: Int {
        #if DEBUG
        if Uninstall.testHome != nil, let v = Uninstall.env("SS_TEST_REPORT_CAP").flatMap(Int.init), v > 0 { return v }
        #endif
        return 200
    }

    static func uninstallReport(_ r: Uninstall.Report, home: String) -> String {
        // Only the item lists are capped, so a long list never pushes the "Not removed" block off the end.
        let cap = listCap
        func section(_ title: String, _ items: [String]) -> [String] {
            guard !items.isEmpty else { return [] }
            let shown = items.count > cap ? Array(items.prefix(cap)) + ["… and \(items.count - cap) more"] : items
            return ["", "\(title) (\(items.count)):"] + shown.map { "  \($0)" }
        }
        let lines = [
            "Semantic Spotlight uninstall report",
            "Generated: \(timestamp())",
            "App: \(appVersion())",
            "macOS: \(macOSVersion())",
        ]
            + section("Removed", r.removed)
            + section("Could not remove", r.failed)
            + section("Still present", r.remaining)
            + notRemovedSection(r.notRemoved)
            + ["", "App bundle: \(r.appStatus)"]
        return Redact.text(lines.joined(separator: "\n"), home: home) + "\n"
    }

    /// The "Not removed" block of the report: only app-created things still present, with how to finish each one.
    /// The text is redacted with the rest of the report.
    static func notRemovedSection(_ entries: [Uninstall.NotRemoved]) -> [String] {
        guard !entries.isEmpty else { return ["", Uninstall.allRemovedSentence, Uninstall.userFilesSentence] }
        var out = ["", "Not removed (\(entries.count)), and how to finish it:"]
        for e in entries {
            out.append("  \(e.title)")
            if let p = e.path { out.append("    path: \(p)") }
            out.append("    why: \(e.why)")
            if let c = e.command { out.append("    to finish: \(c)") }
        }
        return out + ["", Uninstall.userFilesSentence]
    }

    /// Gathered on the main thread: the parts that need AppKit or the engine state.
    static func snapshot() -> Input {
        Input(generated: timestamp(),
              appVersion: appVersion(),
              macOS: macOSVersion(),
              chip: chip(),
              engine: latestStatus == nil ? engineMessage : "running",
              status: latestStatus,
              config: [:],
              loginItem: SMAppService.mainApp.status == .enabled,
              hotkey: Prefs.label,
              logLines: [],
              home: SemPaths.home)
    }

    /// Read on a background thread: the engine config and the last lines of its log.
    static func readConfig(home: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: home + "/.semsearch/config.json")),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        if let v = obj["model"] as? String { out["model"] = v }
        if let v = obj["ocr_languages"] as? [String] { out["ocr_languages"] = v.joined(separator: ", ") }
        if let v = obj["min_similarity"] as? NSNumber { out["min_similarity"] = "\(v.doubleValue)" }
        return out
    }

    static func logTail(path: String, limit: Int = 200) -> [String] {
        guard let data = FileManager.default.contents(atPath: path) else { return [] }
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return Array(lines.suffix(limit))
    }

    static func capped(_ lines: [String], limit: Int = 400) -> [String] {
        lines.count <= limit ? lines : Array(lines.prefix(limit)) + ["… \(lines.count - limit) more lines omitted"]
    }

    static func appVersion() -> String {
        "\(BuildInfo.version) (\(BuildInfo.commit)), built \(BuildInfo.date)"
    }

    static func macOSVersion() -> String { ProcessInfo.processInfo.operatingSystemVersionString }

    static func chip() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }
}
