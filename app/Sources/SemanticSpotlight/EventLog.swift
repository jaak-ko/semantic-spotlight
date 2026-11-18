import Foundation

/// The engine's durable event log, `~/.semsearch/events.jsonl`, rotated to .1 … .7 (the highest is the oldest): one JSON
/// object per line, already free of paths, names and queries. The diagnostics report shows the recent events and the
/// activity by day. An engine that has no event log has no file: `load` returns nil.
enum EventLog {
    struct Event {
        let day: String      // local date, yyyy-MM-dd
        let minute: String   // local time, yyyy-MM-dd HH:mm
        let level: String
        let name: String
        let run: String
        let fields: [(key: String, value: String)]   // sorted by key; ts, level, event and run left out
        var unclean = false   // a daemon start with no stop before it (see markUnclean)

        /// Warnings, errors and unclean starts: shown before the routine events.
        var isProblem: Bool { level == "warn" || level == "error" || unclean }

        /// `2026-11-18 13:11 warn index_error class=OSError run=3f9a1c2b`
        var line: String {
            ([minute, level, name] + fields.map { "\($0.key)=\($0.value)" } + (run.isEmpty ? [] : ["run=\(run)"]))
                .joined(separator: " ")
        }
    }

    /// The files that exist, oldest first.
    static func files(home: String) -> [String] {
        let base = home + "/.semsearch/events.jsonl"
        let rotated = (1...7).reversed().map { "\(base).\($0)" }
        return (rotated + [base]).filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Every event, oldest first. nil when there is no event log.
    static func load(home: String) -> [Event]? {
        let paths = files(home: home)
        guard !paths.isEmpty else { return nil }
        var out: [Event] = []
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path) else { continue }
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                if let e = parse(String(line)) { out.append(e) }
            }
        }
        return markUnclean(out)
    }

    /// One line of the file. A line that is not an event is skipped.
    static func parse(_ line: String) -> Event? {
        guard let data = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let ts = obj["ts"] as? String, let date = isoFormatter.date(from: ts),
              let name = obj["event"] as? String else { return nil }
        var fields: [(key: String, value: String)] = []
        for key in obj.keys.sorted() where !["ts", "level", "event", "run"].contains(key) {
            if let s = obj[key] as? String {
                fields.append((key, s))
            } else if let n = obj[key] as? NSNumber {
                let isBool = CFGetTypeID(n) == CFBooleanGetTypeID()
                fields.append((key, isBool ? (n.boolValue ? "true" : "false") : n.stringValue))
            }
        }
        return Event(day: dayFormatter.string(from: date), minute: minuteFormatter.string(from: date),
                     level: obj["level"] as? String ?? "info", name: name, run: obj["run"] as? String ?? "",
                     fields: fields)
    }

    /// The lines for the report, problems first: every warn or error event and every unclean start (newest 40 at most), then
    /// the most recent routine events, up to `limit` in all. Within `bytes`, problems are kept before routine events; each
    /// part keeps its newest. The lines are in time order. Returns the lines and how many events of each kind are not shown.
    static func recent(_ events: [Event], home: String, limit: Int = 60, problemCap: Int = 40, bytes: Int = 4000)
        -> (lines: [String], routineOmitted: Int, problemsOmitted: Int) {
        let problems = events.indices.filter { events[$0].isProblem }
        let routine = events.indices.filter { !events[$0].isProblem }
        let shownProblems = Array(problems.suffix(problemCap))
        let shownRoutine = Array(routine.suffix(max(0, limit - shownProblems.count)))
        var used = 0
        var keep = Set<Int>()
        for group in [shownProblems, shownRoutine] {
            for i in group.reversed() {   // newest first
                let n = events[i].line.utf8.count + 1
                if used + n > bytes { break }
                used += n
                keep.insert(i)
            }
        }
        let lines = keep.sorted().map { Redact.line(events[$0].line, home: home) }
        return (lines,
                routine.count - routine.filter(keep.contains).count,
                problems.count - problems.filter(keep.contains).count)
    }

    /// Per local day, for the last `days` days that have events, newest first: daemon starts (and how many were unclean: a
    /// start with no stop before it), index runs, index errors and slow searches. The list is cut to `bytes`, and the last
    /// line says how many days are not shown.
    static func activity(_ events: [Event], days: Int = 14, bytes: Int = 1000) -> [String] {
        struct Counts { var starts = 0, unclean = 0, indexRuns = 0, indexErrors = 0, slow = 0 }
        var byDay: [String: Counts] = [:]
        for e in events {   // oldest first
            var c = byDay[e.day, default: Counts()]
            switch e.name {
            case "daemon_start":
                c.starts += 1
                if e.unclean { c.unclean += 1 }
            case "index_start": c.indexRuns += 1
            case "index_error": c.indexErrors += 1
            case "search_slow": c.slow += 1
            default: break
            }
            byDay[e.day] = c
        }
        let all = byDay.keys.sorted(by: >).prefix(days).map { day -> String in
            let c = byDay[day] ?? Counts()
            return "\(day): starts \(c.starts) (unclean \(c.unclean)), index runs \(c.indexRuns), "
                + "index errors \(c.indexErrors), slow searches \(c.slow)"
        }
        let fit = Diagnostics.newest(Array(all.reversed()), bytes: bytes)   // newest days kept
        return fit.omitted > 0 ? fit.lines.reversed() + ["… \(fit.omitted) older days not shown"] : fit.lines.reversed()
    }

    /// Marks each start that came while the engine was still running (no stop since the last start).
    static func markUnclean(_ events: [Event]) -> [Event] {
        var running = false
        return events.map { e in
            var m = e
            if e.name == "daemon_start" {
                m.unclean = running
                running = true
            } else if e.name == "daemon_stop" {
                running = false
            }
            return m
        }
    }

    private static let isoFormatter = ISO8601DateFormatter()
    private static let dayFormatter: DateFormatter = formatter("yyyy-MM-dd")
    private static let minuteFormatter: DateFormatter = formatter("yyyy-MM-dd HH:mm")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format   // the local time zone
        return f
    }
}
