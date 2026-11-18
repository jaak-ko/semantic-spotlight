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
        var home: String
        /// The event log: its recent lines, how many older events are not shown, and the activity by day. `hasEventLog`
        /// is false for an engine that has no event log yet.
        var hasEventLog = false
        var events: [String] = []
        var eventsOmitted = 0          // routine events not shown
        var problemsOmitted = 0        // older warnings, errors and unclean starts not shown
        var activity: [String] = []
        /// The app's log: its last lines, and how many older lines are not shown.
        var appLog: [String] = []
        var appLogOmitted = 0
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
        ]
        if d.hasEventLog {
            lines.append("Recent events (\(d.events.count) shown, problems first, redacted):")
            lines += d.events
            if d.problemsOmitted > 0 { lines.append("… \(d.problemsOmitted) older problem events not shown") }
            if d.eventsOmitted > 0 { lines.append("… \(d.eventsOmitted) routine events not shown") }
        } else {
            lines.append("Recent events: No event log yet")
        }
        lines += ["", "Activity by day (last 14 days with data):"]
        lines += d.activity.isEmpty ? ["No activity recorded"] : d.activity
        lines += ["", "App log (last \(d.appLog.count) lines, redacted):"]
        lines += d.appLog
        if d.appLogOmitted > 0 { lines.append("… \(d.appLogOmitted) older lines not shown") }
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

    /// Read on a background thread: the event log (recent events, activity by day) and the app's log (its last 30 lines).
    /// Each part is cut to a byte budget, so the report stays short; the newest lines are the ones kept.
    static func readLogs(into d: inout Input) {
        let events = EventLog.load(home: d.home)
        d.hasEventLog = events != nil
        if let events {
            let recent = EventLog.recent(events, home: d.home)
            d.events = recent.lines
            d.eventsOmitted = recent.routineOmitted
            d.problemsOmitted = recent.problemsOmitted
            d.activity = EventLog.activity(events)
        }
        // Each line is redacted first, then cut to 90 characters (so a cut never leaves half a path unredacted), and the
        // last 30 lines fit the 2.5 KB budget in the usual case.
        let tail = logTail(path: d.home + "/.semsearch/app-daemon.log", limit: 30)
            .map { Redact.line($0, home: d.home) }
            .map { $0.count > 90 ? String($0.prefix(90)) + "…" : $0 }
        let app = newest(tail, bytes: 2500)
        d.appLog = app.lines
        d.appLogOmitted = app.omitted
    }

    /// The newest of `lines` that fit in `bytes` (oldest first), and how many older lines were left out.
    static func newest(_ lines: [String], bytes: Int) -> (lines: [String], omitted: Int) {
        var kept: [String] = []
        var used = 0
        for line in lines.reversed() {
            used += line.utf8.count + 1
            if used > bytes { break }
            kept.append(line)
        }
        return (kept.reversed(), lines.count - kept.count)
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
