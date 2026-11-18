#if DEBUG
import Foundation

/// Test only (run by the theme test): each folder's own progress from `progress.folders` and the run's `waiting_cloud`.
/// The payload is a fixture: two folders with different progress, one not started, and an older engine with no payload.
enum FolderProgressTests {
    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("folder progress: \(ok ? "ok" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
        }
        let notes = "/fixture/notes", projects = "/fixture/projects", archive = "/fixture/archive"
        let busy: [String: Any] = [
            "files": 40, "chunks": 90, "folders": [notes, projects, archive], "indexing": true,
            "model": "m", "model_ready": true, "waiting_cloud": 4,
            "progress": ["phase": "indexing", "done": 45, "total": 309, "folders": [
                ["path": notes, "phase": "indexing", "done": 15, "total": 300],
                ["path": projects, "phase": "done", "done": 9, "total": 9],
            ]],
        ]
        let s = EngineStatus(busy)
        let own = s.ownFolderProgress
        check("per-folder payload parsed", s.hasFolderProgress && s.folderProgress.count == 2)
        check("own count matched by path", own[notes]?.done == 15 && own[notes]?.total == 300, "\(String(describing: own[notes]))")
        check("own bar fraction", abs((own[notes]?.fraction ?? -1) - 0.05) < 0.0001)
        check("a finished folder is done", own[projects]?.phase == "done" && own[projects]?.fraction == 1)
        check("a folder not reached yet is waiting", own[archive]?.phase == "waiting" && own[archive]?.fraction == 0)
        check("run-wide numbers stay", s.determinate && s.done == 45 && s.total == 309)
        check("waiting_cloud read", s.waitingCloud == 4)
        check("cloud line plural", CloudWaitLine.text(4) == "4 files are in iCloud and are being downloaded")
        check("cloud line singular", CloudWaitLine.text(1) == "1 file is in iCloud and is being downloaded")

        // An older engine: no `folders` key, so no own progress and the run-wide line is all there is.
        let older = EngineStatus(["files": 6, "folders": [notes], "indexing": true,
                                  "progress": ["phase": "indexing", "done": 3, "total": 10]])
        check("older engine: no per-folder payload", !older.hasFolderProgress && older.ownFolderProgress.isEmpty)
        check("older engine: waiting_cloud is 0", older.waitingCloud == 0)
        check("older engine: run-wide line kept", older.progressLine == "Indexing 3 of 10 files")

        // Idle: nothing is running, so no per-folder state is shown even if the engine sent stale entries.
        let idle = EngineStatus(["files": 6, "folders": [notes], "indexing": false, "model_ready": true,
                                 "progress": ["phase": "idle", "done": 0, "total": 0, "folders": []]])
        check("idle: no own progress", idle.ownFolderProgress.isEmpty)

        // A total of 0 has no fraction (the row keeps the indeterminate bar).
        check("unknown total: no fraction", FolderProgress(path: "/x", phase: "indexing", done: 0, total: 0).fraction == nil)
        return failures
    }
}
#endif
