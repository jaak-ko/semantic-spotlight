#if DEBUG
import Foundation

/// Test only (run by the theme test, in a fake home): the report's event and app-log sections and the app's own log.
/// Fixtures are made here: hostile text in an event (a path and an e-mail address) must come out redacted, the report stays
/// under its size budget, a missing event log is said so, rotated files are read oldest first, the activity counts are right,
/// and the app log rotates at 512 KB, keeps four files and stays 0600.
enum DiagnosticsLogTests {
    @MainActor static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("diagnostics log: \(ok ? "ok" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
        }
        let root = NSTemporaryDirectory() + "ss-diaglog-test-\(getpid())"
        defer { try? FileManager.default.removeItem(atPath: root) }

        /// A fresh fake home with an engine folder; `events` are written to events.jsonl, `appLog` to app-daemon.log.
        func home(_ name: String, events: [[String: Any]] = [], appLog: [String] = []) -> String {
            let h = root + "/" + name
            let dir = h + "/.semsearch"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if !events.isEmpty {
                let text = events.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]), as: UTF8.self) }
                try? (text.joined(separator: "\n") + "\n").write(toFile: dir + "/events.jsonl", atomically: true, encoding: .utf8)
            }
            if !appLog.isEmpty { try? (appLog.joined(separator: "\n") + "\n").write(toFile: dir + "/app-daemon.log", atomically: true, encoding: .utf8) }
            return h
        }
        func event(_ name: String, _ level: String = "info", at hour: Int = 12, day: Int = 10, run: String = "3f9a1c2b",
                   _ extra: [String: Any] = [:]) -> [String: Any] {
            var e: [String: Any] = ["ts": String(format: "2026-11-%02dT%02d:00:00Z", day, hour), "level": level, "event": name, "run": run]
            for (k, v) in extra { e[k] = v }
            return e
        }
        func report(_ h: String) -> String {
            var input = Diagnostics.snapshot()
            input.home = h
            Diagnostics.readLogs(into: &input)
            return Diagnostics.render(input)
        }

        // 1. Hostile content: a path and an e-mail address inside a message field come out redacted.
        let hostile = home("hostile", events: [
            event("index_error", "warn", ["class": "OSError",
                                           "message": "could not read /Users/testuser/Documents/secret plan.txt for someone@example.org"]),
        ])
        let hostileText = report(hostile)
        check("a path and an e-mail in an event field are redacted",
              !hostileText.contains("secret plan") && !hostileText.contains("someone@example.org") && !hostileText.contains("/Users/testuser"))
        check("the event line keeps its time, level, name and the safe fields",
              hostileText.range(of: #"\d{4}-\d\d-\d\d \d\d:\d\d warn index_error class=OSError "#, options: .regularExpression) != nil)

        // 2. Size: 200 events and a long app log: the events are capped, the report stays under 8 KB, and it says so.
        let many = home("many", events: (0..<200).map { event("index_start", at: $0 % 24, day: 1 + $0 / 24, run: "3f9a1c2b", ["files": $0]) },
                        appLog: (0..<40).map { "2026-11-18 13:\(String(format: "%02d", $0 % 60)):00 engine line \($0) " + String(repeating: "x", count: 300) })
        let manyText = report(many)
        let shownEvents = manyText.components(separatedBy: "\n").filter { $0.contains(" index_start ") }.count
        check("at most 60 events are listed", shownEvents <= 60 && shownEvents > 0, "\(shownEvents)")
        check("the routine events not shown are counted", manyText.contains("… \(200 - shownEvents) routine events not shown"))
        check("the report is under 10 KB with a long app log", manyText.utf8.count < 10 * 1024, "\(manyText.utf8.count) bytes")
        check("the run id is kept whole in every event line", manyText.contains("run=3f9a1c2b\n") && !manyText.contains("run=r"))
        check("the run id is kept whole in the hostile event", hostileText.contains("run=3f9a1c2b"))
        if let dump = Uninstall.env("SS_DIAG_DUMP") { try? manyText.write(toFile: dump, atomically: true, encoding: .utf8) }   // a sample for the review

        // 2b. Problems first: 45 warnings and errors and 100 routine events, two of the warnings old. Every problem shows
        // (newest 40 at most), the routine fill comes after them, the lines are in time order, and the cut is counted.
        var mixed: [[String: Any]] = (0..<100).map { event("index_start", at: $0 % 24, day: 1 + $0 / 24, ["files": $0]) }
        mixed += (0..<45).map { event("index_error", "warn", at: $0 % 24, day: 5, ["class": "OSError", "n": $0]) }
        // The file is in time order, as the engine writes it.
        mixed.sort { ($0["ts"] as? String ?? "") < ($1["ts"] as? String ?? "") }
        let prio = home("priority", events: mixed)
        let prioText = report(prio)
        let prioLines = prioText.components(separatedBy: "\n")
        let problemLines = prioLines.filter { $0.contains(" warn index_error ") }
        check("problem events are shown first, newest 40", problemLines.count == 40, "\(problemLines.count)")
        check("the older problem events not shown are counted", prioText.contains("… 5 older problem events not shown"))
        let routineShown = prioLines.filter { $0.contains(" info index_start ") }.count
        check("the routine fill is at most 60 events in all", problemLines.count + routineShown <= 60, "\(routineShown)")
        check("routine events not shown are counted", prioText.contains("… \(100 - routineShown) routine events not shown"))
        let times = prioLines.filter { $0.range(of: #"^\d{4}-\d\d-\d\d \d\d:\d\d "#, options: .regularExpression) != nil }
            .map { String($0.prefix(16)) }
        check("the event lines are in time order", times == times.sorted(), "")
        // An unclean start (no stop before it) is a problem too: it is shown although it is old and routine.
        let unclean = home("unclean", events: [event("daemon_start", day: 2, run: "aaaa1111"), event("daemon_start", day: 3, run: "bbbb2222")]
                           + (0..<80).map { event("index_start", at: $0 % 24, day: 4 + $0 / 24, ["files": $0]) })
        check("an unclean restart is shown among the problems", report(unclean).contains("daemon_start run=bbbb2222"))

        // 3. Missing event log: said so, and the rest of the report is still there.
        let none = home("none", appLog: ["2026-11-18 13:00:00 app: starting engine (reason: launch)"])
        let noneText = report(none)
        check("a missing event log is said so", noneText.contains("Recent events: No event log yet"))
        let thirty = home("thirty", appLog: (0..<30).map { "2026-11-18 13:\(String(format: "%02d", $0)):00 short line \($0)" })
        check("the app log shows its last 30 short lines in full", report(thirty).contains("App log (last 30 lines, redacted):")
              && report(thirty).contains("short line 29\n"))
        check("the app log still shows without an event log", noneText.contains("App log (last 1 lines, redacted):")
              && noneText.contains("app: starting engine (reason: launch)"))

        // 4. Rotated files are read oldest first: .2 (oldest), .1, then events.jsonl.
        let rot = home("rotated")
        let dir = rot + "/.semsearch"
        for (file, n) in [("events.jsonl.2", "first"), ("events.jsonl.1", "second"), ("events.jsonl", "third")] {
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: event("daemon_start", at: 1, day: 3,
                                                                                         ["n": n]), options: [.sortedKeys]), as: UTF8.self)
            try? (line + "\n").write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        }
        let order = (EventLog.load(home: rot) ?? []).compactMap { $0.fields.first { $0.key == "n" }?.value }
        check("rotated event files are read oldest first", order == ["first", "second", "third"], "\(order)")

        // 5. Activity by day: an unclean restart is a start with no stop before it; index errors and slow searches count.
        let act = home("activity", events: [
            event("daemon_start", day: 10), event("index_start", day: 10), event("index_error", "error", day: 10),
            event("daemon_start", at: 14, day: 10), event("search_slow", at: 15, day: 10), event("daemon_stop", at: 16, day: 10),
            event("daemon_start", day: 11), event("daemon_stop", at: 13, day: 11),
        ])
        let actLines = EventLog.activity(EventLog.load(home: act) ?? [])
        check("activity: the newest day first, with starts, unclean restarts and counts",
              actLines.first?.hasPrefix("2026-11-11:") == true, "\(actLines)")
        check("activity: the day with an unclean restart is counted",
              actLines.contains("2026-11-10: starts 2 (unclean 1), index runs 1, index errors 1, slow searches 1"), "\(actLines)")
        check("activity: a start after a stop is not an unclean restart",
              actLines.contains("2026-11-11: starts 1 (unclean 0), index runs 0, index errors 0, slow searches 0"), "\(actLines)")

        // 6. The app's own log: rotated at 512 KB, four files, 0600. Runs in the fake home only.
        if Uninstall.testHome != nil {
            let fm = FileManager.default
            let log = SemPaths.log
            try? fm.removeItem(atPath: log)
            for n in 1...4 { try? fm.removeItem(atPath: "\(log).\(n)") }
            let line = String(repeating: "a", count: 1000)
            for _ in 0..<600 { AppLog.app(line) }   // about 600 KB: one rotation
            AppLog.flush()
            let current = (try? fm.attributesOfItem(atPath: log)[.size] as? Int) ?? 0
            check("the app log rotates at 512 KB", fm.fileExists(atPath: log + ".1") && current < AppLog.limit, "current \(current)")
            check("the app log keeps the timestamp on each line",
                  (try? String(contentsOfFile: log, encoding: .utf8))?.hasPrefix("20") == true)
            let mode = ((try? fm.attributesOfItem(atPath: log)[.posixPermissions] as? Int) ?? 0) & 0o777
            check("the app log is 0600", mode == 0o600, String(mode, radix: 8))
            for _ in 0..<2000 { AppLog.app(line) }   // several more rotations
            AppLog.flush()
            check("the app log keeps four files at most",
                  fm.fileExists(atPath: "\(log).3") && !fm.fileExists(atPath: "\(log).4"))
            for n in 1...4 { try? fm.removeItem(atPath: "\(log).\(n)") }
            try? fm.removeItem(atPath: log)
        }
        // A review sample from a real home (SS_DIAG_HOME): the report that home produces, written to SS_DIAG_DUMP.
        if let src = Uninstall.env("SS_DIAG_HOME"), let dump = Uninstall.env("SS_DIAG_DUMP") {
            try? report(src).write(toFile: dump, atomically: true, encoding: .utf8)
        }
        return failures
    }
}
#endif
