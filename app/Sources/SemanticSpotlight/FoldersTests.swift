#if DEBUG
import Foundation

/// Test only (`--folders-test-for-test`, test roots, headless): adding a folder while the engine starts, fails, or is
/// missing its model. The engine is scripted (no socket, no daemon, no network). Short waits keep it quick.
enum FoldersTests {
    private static var checks = 0
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool) {
        checks += 1
        if !ok { failures += 1 }
        MenuBarIcon.testLog("folders test: \(ok ? "ok" : "FAIL") \(name)")
    }

    /// An engine whose socket is absent until `pingsUntilUp` pings have been asked, and whose add answers `addResult`.
    final class ScriptedEngine: FolderEngine {
        var pingsUntilUp = 0
        var pings = 0
        var addResult: AddProblem?
        var startCount = 0
        var addCount = 0
        func ping(_ completion: @escaping (Bool) -> Void) {
            pings += 1
            let up = pings > pingsUntilUp
            DispatchQueue.main.async { completion(up) }
        }
        func addFolder(_ path: String, completion: @escaping (AddProblem?) -> Void) {
            addCount += 1
            let result = addResult
            DispatchQueue.main.async { completion(result) }
        }
        func startEngine() { startCount += 1 }
        func removeFolder(_ path: String) {}
    }

    private static func row(_ path: String) -> FolderRow? {
        FolderTracker.shared.rows(nil).first { $0.path == path }
    }

    /// Runs `body` after `seconds` on the main queue; the tracker's callbacks run on it too.
    private static func after(_ seconds: Double, _ body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: body)
    }

    /// Real socket checks: the production EngineManager against tools/fake_engine.py. FOLDERS_SOCKET_TEST=present runs
    /// with the fake engine up (its state names a model error for one path); =absent runs with no engine at all.
    static func socketChecks(then next: @escaping () -> Void) {
        let engine = EngineManager.shared
        engine.ping { up in
            check("socket: the fake engine answers ping", up)
            engine.addFolder("/tmp/fake/socket-ok") { problem in
                check("socket: add succeeds against the fake engine", problem == nil)
                after(0.3) {
                    engine.addFolder("/tmp/fake/socket-model") { problem in
                        check("socket: a model-missing reply is the model cause", problem == .modelMissing)
                        after(0.3) { next() }
                    }
                }
            }
        }
    }

    static func run() {
        switch ProcessInfo.processInfo.environment["FOLDERS_SOCKET_TEST"] {
        case "present"?:
            socketChecks {
                MenuBarIcon.testLog("folders test: done, \(checks) checks, \(failures) failures")
                AppQuit.now()
            }
        case "absent"?:
            // No engine at all: the socket is missing, so the cause is "not running".
            EngineManager.shared.ping { up in
                check("socket: no socket, ping is false", !up)
                EngineManager.shared.addFolder("/tmp/fake/socket-gone") { problem in
                    check("socket: no socket is the not-running cause", problem == .notRunning)
                    MenuBarIcon.testLog("folders test: done, \(checks) checks, \(failures) failures")
                    AppQuit.now()
                }
            }
        default:
            scriptedChecks()
        }
    }

    private static func scriptedChecks() {
        let tracker = FolderTracker.shared
        tracker.waitBudget = 0.6
        tracker.pollInterval = 0.05
        let engine = ScriptedEngine()
        tracker.engine = engine

        // 1. Pure classification of the request's errors.
        check("unreachable socket is 'not running'", AddProblem.from(EngineError.unreachable) == .notRunning)
        check("no reply in time is 'not running' (still loading)",
              AddProblem.from(EngineError.failed("engine closed the connection or timed out")) == .notRunning)
        check("model not installed is the model cause",
              AddProblem.from(EngineError.failed("model intfloat/multilingual-e5-small is not installed; run `semsearch fetch-model`")) == .modelMissing)
        check("any other engine text is a genuine engine error",
              AddProblem.from(EngineError.failed("not a folder: /x")) == .engine("not a folder: /x"))

        // 2. The socket is absent, then the engine comes up: "Starting the engine…", then the add succeeds. No error row.
        let up = "/tmp/fake/startup"
        engine.pingsUntilUp = 3
        tracker.add(up)
        check("while the engine starts, the row says so", row(up)?.text == "Starting the engine…" && row(up)?.retry == false)
        after(0.8) {
            check("the add succeeds once the engine answers (no error row)", engine.addCount == 1 && row(up)?.tone != .error)
            check("the row is not 'not added'", row(up)?.text.hasPrefix("Not added") == false)

            // 3. The engine never appears: a friendly message, the folder stays listed, Retry is offered.
            let never = "/tmp/fake/never"
            engine.pingsUntilUp = 100_000
            engine.pings = 0
            tracker.add(never)
            after(1.2) {
                let r = row(never)
                check("engine never appears: the folder stays listed", r != nil)
                check("engine never appears: plain message, 'Not added yet'", r?.text == "Not added yet. The search engine isn't running yet.")
                check("engine never appears: Retry is offered", r?.retry == true && r?.tone == .error)

                // 4. Retry after the engine appears: it starts the engine, waits, adds, and the row turns normal.
                engine.pingsUntilUp = engine.pings + 2
                let startsBefore = engine.startCount
                tracker.retry(never)
                check("retry starts the engine", engine.startCount == startsBefore + 1)
                after(0.8) {
                    let r = row(never)
                    check("retry after the engine appears: the add succeeds", engine.addCount >= 2 && r?.text.hasPrefix("Not added") == false)
                    check("retry after the engine appears: the row is normal again", r?.tone != .error && r?.retry == false)

                    // 5. The model is missing: the download hint, with Retry (after the download).
                    let model = "/tmp/fake/model"
                    engine.pingsUntilUp = 0
                    engine.addResult = .modelMissing
                    tracker.add(model)
                    after(0.5) {
                        let r = row(model)
                        check("model missing: the download hint", r?.text == "Not added yet. Download the language model first.")
                        check("model missing: no technical detail is shown", r?.detail == nil && r?.retry == true)

                        // 6. A genuine engine error: its text is the detail, behind Show details.
                        let broken = "/tmp/fake/broken"
                        engine.addResult = .engine("disk full while indexing")
                        tracker.add(broken)
                        after(0.5) {
                            let r = row(broken)
                            check("engine error: the row says the engine reported an error", r?.text == "Not added yet. The search engine reported an error.")
                            check("engine error: its text is the detail", r?.detail == "disk full while indexing")

                            // Removing a not-added folder is the only way it goes.
                            tracker.remove(never)
                            check("remove drops the folder from the list", row(never) == nil)

                            MenuBarIcon.testLog("folders test: done, \(checks) checks, \(failures) failures")
                            AppQuit.now()
                        }
                    }
                }
            }
        }
    }
}
#endif
