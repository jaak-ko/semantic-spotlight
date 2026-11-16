#if DEBUG
import AppKit

/// Test only (run by the theme test): the welcome window's four states, and what each shows. The state comes from the
/// model; the dot is the state's step; the primary button of each state is the one that is enabled.
enum OnboardingStateTests {
    @MainActor static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("onboarding state: \(ok ? "ok" : "FAIL") \(name)")
        }
        // 1: the model is missing and nothing is downloading.
        let m1 = OnboardingModel()
        check("state 1 (model missing): stage download, dot 1", m1.stage == .download && m1.stage.dot == 0)
        check("state 1: the folder button is not shown in this state (the gate stays closed)", !m1.canChooseFolder)

        // 2: downloading, retrying, and failed are all the second state, on the first dot.
        let m2 = OnboardingModel()
        m2.download = .running
        check("state 2 (downloading): stage downloading, dot 1", m2.stage == .downloading && m2.stage.dot == 0)
        m2.download = .retrying(attempt: 2, max: 5)
        check("state 2 (retrying): stage downloading", m2.stage == .downloading)
        m2.download = .failed(message: "The download stopped unexpectedly. Try again.", detail: "exit 1")
        check("state 2 (error): stage downloading, with the friendly message", m2.stage == .downloading)

        // 3: the model is ready, no folder yet: the folder button is enabled.
        let m3 = OnboardingModel()
        m3.apply(EngineStatus(["files": 0, "chunks": 0, "folders": [], "indexing": false, "model": "m", "model_ready": true]), rows: [])
        check("state 3 (model ready): stage ready, dot 2", m3.stage == .ready && m3.stage.dot == 1)
        check("state 3: Choose folder is enabled (the gate is open once the model is ready)", m3.canChooseFolder)
        check("state 3: Start searching is disabled (nothing is indexed)", !m3.canFinish)

        // 4: a folder is indexed: Start searching is enabled, dot 3.
        let m4 = OnboardingModel()
        m4.apply(EngineStatus(["files": 6, "chunks": 20, "folders": ["/fixture/notes"], "indexing": false, "model": "m",
                               "model_ready": true, "folder_stats": [["path": "/fixture/notes", "files": 6]]]),
                 rows: [FolderRow(id: "/fixture/notes", path: "/fixture/notes", text: "Done: 6 files indexed", tone: .ok)])
        check("state 4 (indexed): stage indexed, dot 3", m4.stage == .indexed && m4.stage.dot == 2)
        check("state 4: Start searching is enabled", m4.canFinish)
        MenuBarIcon.testLog("onboarding state: done, \(failures) failure(s)")
        return failures
    }
}
#endif
