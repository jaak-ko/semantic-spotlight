import AppKit
import ServiceManagement

/// Uninstall: one inventory of everything the app and its engine create, and one function that removes it.
/// The inventory matches engine/UNINSTALL_INVENTORY.md. Only exact known paths are deleted, and the user's
/// own files and indexed folders are never touched. The app does this itself, so it works even if the
/// engine cannot start. The confirmation and summary are in UninstallSheet.swift.
enum Uninstall {
    static let bundleID = "local.semanticspotlight.app"
    static let appName = "Semantic Spotlight"
    static let gpuLabel = "GPU shader cache (rebuilt automatically)"

    /// Test mode: SS_UNINSTALL_HOME (plus SS_UNINSTALL_APP, SS_UNINSTALL_CACHE_DIR, SS_UNINSTALL_TEMP_DIR)
    /// redirect every root, and the real UserDefaults and login-item calls are skipped.
    // Test roots exist in DEBUG builds only (the check scripts build debug). A release build reads no test variable,
    // so its uninstall always works on the real home, the real caches and the real app bundle.
    #if DEBUG
    static func env(_ key: String) -> String? { ProcessInfo.processInfo.environment[key] }
    static var testHome: String? { env("SS_UNINSTALL_HOME") }
    static var appPath: String { env("SS_UNINSTALL_APP") ?? Bundle.main.bundlePath }
    #else
    static var testHome: String? { nil }
    static var appPath: String { Bundle.main.bundlePath }
    #endif
    static var home: String { testHome ?? SemPaths.home }

    /// The engine home. Deleted as one directory, which also removes everything the engine creates in it.
    static var engineDir: String { home + "/.semsearch" }

    struct Item {
        let label: String
        let path: String
        var container = false   // the engine home: deleted whole; its unlisted contents go with it
    }

    struct Report {
        var removed: [String] = []
        var failed: [String] = []
        var remaining: [String] = []   // inventory paths still present after the delete step
        var appStatus = ""
        var failures: [Failure] = []
        var notRemoved: [NotRemoved] = []
    }

    struct Failure {
        let path: String
        let why: String
        var command: String? = nil
    }

    /// One entry of "Not removed": what it is, its path (nil when the app cannot know it), why it stays, and how to finish it.
    struct NotRemoved {
        let title: String
        let path: String?
        let why: String
        let command: String?
    }

    static let tccCommand = "/usr/bin/tccutil reset All \(bundleID)"

    /// Said on every summary and in every report, whatever was removed.
    static let userFilesSentence = "Your own files and the folders you indexed were left alone."
    static let allRemovedSentence = "Everything the app created was removed."

    // MARK: - Inventory

    /// Everything the app creates. Paths are exact; the only pattern is `mpsgraph-*` inside the MPSGraph folder.
    static func inventory() -> [Item] {
        let e = engineDir
        var items = [
            Item(label: "Search index", path: e + "/index.db"),
            Item(label: "Search index", path: e + "/index.db-wal"),
            Item(label: "Search index", path: e + "/index.db-shm"),
            Item(label: "Engine socket", path: e + "/daemon.sock"),
            Item(label: "Downloaded language model", path: e + "/models"),
            Item(label: "Engine caches and temp files", path: e + "/hf"),
            Item(label: "Engine caches and temp files", path: e + "/torch"),
            Item(label: "Engine caches and temp files", path: e + "/st"),
            Item(label: "Engine caches and temp files", path: e + "/cache"),
            Item(label: "Engine caches and temp files", path: e + "/tmp"),
            Item(label: "Settings", path: e + "/config.json"),
            Item(label: "Engine log", path: e + "/app-daemon.log"),
            Item(label: "Engine home (~/.semsearch)", path: e, container: true),
        ]
        let h = home
        items += [
            Item(label: "Preferences", path: h + "/Library/Preferences/\(bundleID).plist"),
            Item(label: "Saved window state", path: h + "/Library/Saved Application State/\(bundleID).savedState"),
            Item(label: "Caches", path: h + "/Library/Caches/\(bundleID)"),
            Item(label: "Web storage", path: h + "/Library/HTTPStorages/\(bundleID)"),
            Item(label: "WebKit data", path: h + "/Library/WebKit/\(bundleID)"),
            Item(label: "Application Support", path: h + "/Library/Application Support/\(appName)"),
            Item(label: "Logs", path: h + "/Library/Logs/\(appName)"),
            Item(label: "Launch agent", path: h + "/Library/LaunchAgents/\(bundleID).plist"),
        ]
        items += gpuItems()
        items.append(Item(label: "The app itself", path: appPath))
        return items
    }

    /// The macOS per-user GPU cache folder keyed to this app's bundle id: the engine's Metal cache, written under our
    /// own id. Shared caches (org.python.python, com.apple.metal, MPS graph folders) belong to other software and are
    /// never removed.
    static func gpuRoots() -> (cache: String, temp: String)? {
#if DEBUG
        if testHome != nil {
            guard let c = env("SS_UNINSTALL_CACHE_DIR"), let t = env("SS_UNINSTALL_TEMP_DIR") else { return nil }
            return (slash(c), slash(t))
        }
#endif
        guard let c = darwinDir(_CS_DARWIN_USER_CACHE_DIR), let t = darwinDir(_CS_DARWIN_USER_TEMP_DIR) else { return nil }
        return (c, t)
    }

    static func gpuItems() -> [Item] {
        guard let g = gpuRoots() else { return [] }
        // The engine child runs under this bundle id, so macOS keys its Metal cache by it: the whole folder is ours.
        return [Item(label: gpuLabel, path: g.cache + bundleID)]
    }

    static func slash(_ path: String) -> String { path.hasSuffix("/") ? path : path + "/" }

    static func darwinDir(_ name: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(name, &buf, buf.count) > 0 else { return nil }
        return slash(String(cString: buf))
    }

    // MARK: - Safety

    /// Refuses anything that is not one of the expected locations.
    static func allowed(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let h = (home as NSString).standardizingPath
        if p == "/" || p == h || h == "/" || h.isEmpty { return false }
        if p == (appPath as NSString).standardizingPath { return p.hasSuffix(".app") }
        let engine = (engineDir as NSString).standardizingPath   // standardize both sides: TMPDIR paths can contain "//"
        if p == engine || p.hasPrefix(engine + "/") || p.hasPrefix(h + "/Library/") { return true }
        if let g = gpuRoots() {
            let cache = (g.cache as NSString).standardizingPath
            if p == cache + "/" + bundleID || p.hasPrefix(cache + "/" + bundleID + "/") { return true }
        }
        return false
    }

    /// The file type bits of `path` (symlinks not followed), or nil if it does not exist.
    static func kind(_ path: String) -> mode_t? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_mode & S_IFMT
    }

    static func exists(_ path: String) -> Bool { kind(path) != nil }

    // MARK: - Sizes

    /// Bytes on disk under `root`, symlinks not followed. Gives up at `deadline` or after `maxEntries`
    /// entries and reports `complete: false`. `skip` names subtrees left out (the models folder, for the engine home).
    static func boundedSize(_ root: String, skip: [String] = [], deadline: Date, maxEntries: Int = 300_000) -> (bytes: Int64, complete: Bool) {
        guard let k = kind(root), k != S_IFLNK else { return (0, true) }
        var st = stat()
        lstat(root, &st)
        if k != S_IFDIR { return (Int64(st.st_blocks) * 512, true) }
        guard let walk = FileManager.default.enumerator(atPath: root) else { return (0, true) }
        var total: Int64 = 0
        var seen = 0
        for case let rel as String in walk {
            let full = root + "/" + rel
            if skip.contains(full) { walk.skipDescendants(); continue }
            seen += 1
            if seen > maxEntries || Date() > deadline { return (total, false) }
            var s = stat()
            guard lstat(full, &s) == 0 else { continue }
            let t = s.st_mode & S_IFMT
            if t != S_IFDIR && t != S_IFLNK { total += Int64(s.st_blocks) * 512 }
        }
        return (total, true)
    }

    /// Listed engine items that exist. A symlinked engine home is one link, so its contents are not listed.
    static func engineChildren(_ items: [Item]) -> [Item] {
        guard kind(engineDir) == S_IFDIR else { return [] }
        return items.filter { !$0.container && $0.path.hasPrefix(engineDir + "/") && exists($0.path) }
    }

    /// One row of the confirmation sheet. `paths` are the existing things it covers; `skip` is left out of the size.
    struct Group {
        let title: String
        let subtitle: String
        let paths: [String]
        let skip: [String]
    }

    /// The short summary: about seven rows, each with one size. Only things that exist appear.
    static func groups() -> [Group] {
        let h = home
        let models = engineDir + "/models"
        let plist = h + "/Library/Preferences/\(bundleID).plist"
        let saved = h + "/Library/Saved Application State/\(bundleID).savedState"
        let caches = [
            h + "/Library/Caches/\(bundleID)", h + "/Library/HTTPStorages/\(bundleID)", h + "/Library/WebKit/\(bundleID)",
            h + "/Library/Application Support/\(appName)", h + "/Library/Logs/\(appName)",
        ]
        let candidates = [
            Group(title: "Search index, settings and engine data", subtitle: "~/.semsearch, except the model",
                  paths: [engineDir], skip: [models]),
            Group(title: "Downloaded language model", subtitle: "~/.semsearch/models",
                  paths: [models], skip: []),
            Group(title: "Preferences and window state", subtitle: "~/Library/Preferences, Saved Application State",
                  paths: [plist, saved], skip: []),
            Group(title: "Caches, web storage and logs", subtitle: "~/Library/Caches, HTTPStorages, WebKit, Application Support, Logs",
                  paths: caches, skip: []),
            Group(title: gpuLabel, subtitle: "the app's own macOS shader cache folder",
                  paths: gpuItems().map(\.path), skip: []),
            Group(title: "Login item and launch agent", subtitle: "~/Library/LaunchAgents",
                  paths: [h + "/Library/LaunchAgents/\(bundleID).plist"], skip: []),
            Group(title: "The app itself", subtitle: (appPath as NSString).abbreviatingWithTildeInPath,
                  paths: [appPath], skip: []),
        ]
        return candidates.compactMap { g in
            let present = g.paths.filter(exists)
            return present.isEmpty ? nil : Group(title: g.title, subtitle: g.subtitle, paths: present, skip: g.skip)
        }
    }

    /// Every existing item, one line each, for the scrollable detail list.
    static func detailLines() -> [String] {
        inventory().filter { exists($0.path) }.map { "\($0.label): \(($0.path as NSString).abbreviatingWithTildeInPath)" }
    }

    /// Keeps a list bounded: long lists end with a count of what was left out.
    static func capped(_ lines: [String], limit: Int = 200) -> [String] {
        lines.count <= limit ? lines : Array(lines.prefix(limit)) + ["… and \(lines.count - limit) more"]
    }

    // MARK: - Engine

    /// Stops the daemon we started, then any process still running from this app's runtime.
    static func stopEngine() {
        EngineManager.shared.shutdown()   // SIGTERM, then SIGKILL (see EngineManager.shutdown)
        let prefix = (appPath as NSString).standardizingPath + "/Contents/Resources/runtime/"
        for pid in runningPids(under: prefix) { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, !runningPids(under: prefix).isEmpty { usleep(100_000) }
        for pid in runningPids(under: prefix) { kill(pid, SIGKILL) }
    }

    /// PIDs whose command line starts inside `prefix`, from `ps`.
    static func runningPids(under prefix: String) -> [pid_t] {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        var pids: [pid_t] = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            guard let space = trimmed.firstIndex(of: " "), let pid = Int32(trimmed[..<space]) else { continue }
            if String(trimmed).contains(prefix), pid != getpid() { pids.append(pid) }
        }
        return pids
    }

    // MARK: - Delete

    /// Deletes one exact path. A symlink is unlinked, never followed. Returns an error text, or nil.
    static func remove(_ path: String) -> String? {
        guard let k = kind(path) else { return nil }
        if k == S_IFLNK {
            return unlink(path) == 0 ? nil : String(cString: strerror(errno))
        }
        makeWritable(path)
        do {
            try FileManager.default.removeItem(atPath: path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Read-only folders would block deleting their contents, so give the owner write access first.
    static func makeWritable(_ path: String) {
        for rel in [""] + ((try? FileManager.default.subpathsOfDirectory(atPath: path)) ?? []) {
            let full = rel.isEmpty ? path : path + "/" + rel
            var st = stat()
            if lstat(full, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                chmod(full, st.st_mode | S_IRWXU)
            }
        }
    }

    /// Stop, delete the inventory, re-check it, reset the macOS permission records, and list what stays.
    /// The app bundle is handed to a helper. Call from a background thread: it can take a while for a large index.
    static func perform() -> Report {
        var report = Report()
        let items = inventory()
        if testHome == nil {
            try? SMAppService.mainApp.unregister()
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        stopEngine()

        // 1. The engine home, as one directory. Its listed children are reported as removed.
        let children = engineChildren(items)
        if exists(engineDir) {
            if !allowed(engineDir) {
                fail(&report, engineDir, "refused, not an expected location")
            } else if let error = remove(engineDir) {
                fail(&report, engineDir, error)
            } else {
                report.removed += children.map { "\($0.label): \($0.path)" }
                report.removed.append("Engine home (~/.semsearch): \(engineDir)")
            }
        }

        // 2. Library items and GPU caches, by exact path.
        for item in items where !item.container && !item.path.hasPrefix(engineDir + "/") && item.path != appPath {
            guard exists(item.path) else { continue }
            guard allowed(item.path) else {
                fail(&report, item.path, "refused, not an expected location")
                continue
            }
            if let error = remove(item.path) {
                fail(&report, item.path, error)
            } else {
                report.removed.append("\(item.label): \(item.path)")
            }
        }

        // 4. Re-check every inventory path, then look for anything named after the app that the inventory does not know.
        report.remaining = items.filter { $0.path != appPath && exists($0.path) }.map(\.path)
        let inventoryPaths = Set(items.map { ($0.path as NSString).standardizingPath })
        for path in appNamedLeftovers() where !inventoryPaths.contains(path) && exists(path) {
            report.notRemoved.append(NotRemoved(title: "Leftover named after the app", path: path,
                why: "found after the uninstall; it is not in the list of things the app creates, so it was not removed.",
                command: "rm -rf \"\(path)\""))
        }

        // 5. A login item that is still on after unregistering.
        if testHome == nil, SMAppService.mainApp.status == .enabled {
            report.notRemoved.append(NotRemoved(title: "Login item still on", path: nil,
                why: "macOS did not let the app unregister it.",
                command: "System Settings → General → Login Items: switch off Semantic Spotlight."))
        }

        // 6. The per-app privacy records macOS keeps outside the app's files.
        let tcc = resetPermissions()
        if !tcc.ok {
            report.notRemoved.append(NotRemoved(title: "Permission records macOS keeps for the app", path: nil,
                why: "macOS keeps these outside the app's files; the reset did not complete (\(tcc.detail)).",
                command: tccCommand))
        }

        // 7. The app bundle, by a helper once this process exits.
        let bundle = removeBundle()
        report.appStatus = bundle.message
        if !bundle.ok {
            report.failures.append(Failure(path: appPath, why: bundle.message,
                                           command: "Move SemanticSpotlight.app to the Trash (or eject the disk image it runs from)."))
            report.failed.append("\(appPath): \(bundle.message)")
        }

        // 8. What stays: the standing list, then every failure and leftover.
        report.notRemoved = report.notRemoved + failureEntries(report)
        return report
    }

    /// Records a failure, both as a line of the report and as an entry of "Not removed".
    static func fail(_ report: inout Report, _ path: String, _ why: String) {
        report.failed.append("\(path): \(why)")
        report.failures.append(Failure(path: path, why: why))
    }

    /// Every failure and leftover, each once, with the command that finishes it.
    static func failureEntries(_ r: Report) -> [NotRemoved] {
        var seen = Set<String>()
        var out: [NotRemoved] = []
        for f in r.failures where seen.insert(f.path).inserted {
            let parent = (f.path as NSString).deletingLastPathComponent
            out.append(NotRemoved(title: "Could not remove", path: f.path, why: f.why,
                                  command: f.command ?? "chmod u+w \"\(parent)\" && rm -rf \"\(f.path)\""))
        }
        for p in r.remaining where seen.insert(p).inserted {
            out.append(NotRemoved(title: "Still present after the removal", path: p,
                                  why: "it is still there after the removal ran.",
                                  command: "rm -rf \"\(p)\""))
        }
        return out
    }

    /// Clears the per-app privacy records macOS keeps. Test mode makes no real call: SS_TEST_TCC_EXIT
    /// (when set) stands in for the tool's exit code, and without it the step is reported as skipped.
    static func resetPermissions() -> (ok: Bool, detail: String) {
#if DEBUG
        if testHome != nil {
            guard let code = env("SS_TEST_TCC_EXIT"), !code.isEmpty else { return (true, "skipped in test mode") }
            let c = Int32(code) ?? 1
            return (c == 0, "exit \(c), test")
        }
#endif
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        tool.arguments = ["reset", "All", bundleID]
        do {
            try tool.run()
            tool.waitUntilExit()
            return (tool.terminationStatus == 0, "exit \(tool.terminationStatus)")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Anything named after the app, in the places the app and its engine write. Unknown leftovers are listed,
    /// never silently missed. Only names are checked: nothing here is removed by this scan.
    static func appNamedLeftovers() -> [String] {
        var roots = ["Caches", "Saved Application State", "HTTPStorages", "WebKit", "Preferences", "Logs",
                     "Application Support", "LaunchAgents"].map { home + "/Library/" + $0 }
        roots.append(tempRoot)
        if let g = gpuRoots() { roots += [g.cache, g.temp] }
        var found: [String] = []
        for root in roots {
            let base = (root as NSString).standardizingPath
            for name in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] where isAppNamed(name) {
                found.append(base + "/" + name)
            }
        }
        return found
    }

    /// The temporary folder. In test mode it is the TMPDIR the test sets: FileManager's own temporary folder
    /// ignores TMPDIR on macOS, so a test would otherwise reach into the user's real temporary folder.
    static var tempRoot: String {
        #if DEBUG
        if testHome != nil { return env("TMPDIR") ?? "/tmp" }
        #endif
        return FileManager.default.temporaryDirectory.path
    }

    static func isAppNamed(_ name: String) -> Bool {
        let n = name.lowercased().replacingOccurrences(of: " ", with: "")
        return n.contains("semanticspotlight") || n.contains("ss-uninstall")
    }

    // MARK: - App bundle

    static let helperScript = """
    #!/bin/sh
    # Deletes the Semantic Spotlight app bundle after the app has quit, then deletes itself.
    pid="$1"; app="$2"; trash="$3"
    while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
    rm -rf -- "$app"
    if [ -e "$app" ]; then mv -- "$app" "$trash/" 2>/dev/null; fi
    [ -e "$app" ] && exit 1
    rm -f -- "$0"
    """

    /// Starts a detached helper that deletes the bundle once this process exits. Falls back to the Trash.
    static func removeBundle() -> (ok: Bool, message: String) {
        let app = (appPath as NSString).standardizingPath
        guard allowed(app) else { return (false, "The app was not removed: \(app) is not an expected location.") }
        if app.hasPrefix("/Volumes/") {
            return (false, "The app runs from a read-only disk image (\(app)). It cannot be removed from there: eject the disk image.")
        }
        guard access((app as NSString).deletingLastPathComponent, W_OK) == 0 else {
            return (false, "The app is in a read-only folder (\(app)). Move it to the Trash yourself.")
        }
        let script = URL(fileURLWithPath: tempRoot).appendingPathComponent("ss-uninstall-\(UUID().uuidString).sh")
        do {
            try helperScript.write(to: script, atomically: true, encoding: .utf8)
        } catch {
            return (false, "Could not write the removal helper: \(error.localizedDescription)")
        }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [script.path, String(getpid()), app, home + "/.Trash"]
        do {
            try helper.run()
        } catch {
            return (false, "Could not start the removal helper: \(error.localizedDescription)")
        }
        return (true, "The app bundle is deleted by a helper as soon as Semantic Spotlight quits. If it stays, move it to the Trash.")
    }

    #if DEBUG
    // MARK: - Test entry points (need SS_UNINSTALL_HOME)

    /// `--list-inventory`: prints every inventory path as "item <path>" or "container <path>".
    static func listForTest() -> Int32 {
        guard testHome != nil else {
            print("refused: set SS_UNINSTALL_HOME for --list-inventory")
            return 2
        }
        for item in inventory() { print("\(item.container ? "container" : "item") \(item.path)") }
        return 0
    }

    /// `--uninstall-for-test`. Exit 0 only if nothing is left behind.
    static func runForTest() -> Int32 {
        guard testHome != nil else {
            print("refused: set SS_UNINSTALL_HOME for --uninstall-for-test")
            return 2
        }
        let report = perform()
        report.removed.forEach { print("removed: \($0)") }
        report.failed.forEach { print("failed: \($0)") }
        report.remaining.forEach { print("remaining: \($0)") }
        report.notRemoved.forEach { print("notremoved: \($0.title)\t\($0.path ?? "")\t\($0.why)\t\($0.command ?? "")") }
        print("summary: \(report.notRemoved.isEmpty ? allRemovedSentence : "Some things the app created are still present (see the list).") \(userFilesSentence)")
        print("app: \(report.appStatus)")
        return report.failed.isEmpty && report.remaining.isEmpty ? 0 : 1
    }
    #endif
}
