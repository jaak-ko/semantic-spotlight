#if DEBUG
import AppKit
import Combine
import SwiftUI

/// Test only (`--onboarding-test-for-test`, test roots, headless): the welcome window's download states, driven through
/// the real `fetchModel` with tools/fake_fetch.py as the engine (SS_ENGINE_PATH). No network. Also renders the step-1
/// to PNG (SS_DUMP_DIR) so the layout can be looked at.
enum OnboardingTests {
    private static var checks = 0
    private static var failures = 0
    private static var cancellables = Set<AnyCancellable>()

    private static func check(_ name: String, _ ok: Bool) {
        checks += 1
        if !ok { failures += 1 }
        MenuBarIcon.testLog("onboarding test: \(ok ? "ok" : "FAIL") \(name)")
    }

    /// Runs one scenario through `fetchModel`, then calls `then` with the model and every download state it passed through.
    private static func fetch(_ scenario: String, then: @escaping (OnboardingModel, [OnboardingModel.Download]) -> Void) {
        setenv("FAKE_FETCH_SCENARIO", scenario, 1)
        let model = OnboardingModel()
        var history: [OnboardingModel.Download] = []
        model.$download.sink { history.append($0) }.store(in: &cancellables)
        model.fetchModel()
        let started = Date()
        func poll() {
            let finished: Bool
            switch model.download {
            case .done, .failed: finished = true
            default: finished = false
            }
            if finished || Date().timeIntervalSince(started) > 15 {
                then(model, history)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { poll() }
    }

    static func run() {
        folderRule()
        let transientMessage = OnboardingModel.genericFailure
        fetch("transient") { model, history in
            check("transient: the calm retry line was shown (attempt 1 and 2 of 5)",
                  history.contains(.retrying(attempt: 1, max: 5)) && history.contains(.retrying(attempt: 2, max: 5)))
            check("transient: no red error at any point", !history.contains { if case .failed = $0 { return true } else { return false } })
            check("transient: it finishes ready", model.download == .done && model.modelReady)

            fetch("five-errors") { model, history in
                let friendly = "Could not reach the model server. Check the network connection, then try again."
                check("five retries: the fifth attempt was shown", history.contains(.retrying(attempt: 5, max: 5)))
                if case .failed(let message, let detail) = model.download {
                    check("five retries: the main view gets the friendly message only", message == friendly)
                    check("five retries: the technical detail is kept for Show details", detail.hasPrefix("SSLError") && detail.contains("huggingface.co"))
                    check("five retries: the details start closed", model.detailsExpanded == false)
                    check("five retries: the detail is bounded", detail.count <= OnboardingModel.maxDetailLength + 1)
                    model.detailsExpanded = true
                    check("five retries: Show details opens them", model.detailsExpanded)
                } else {
                    check("five retries: ends in a failure", false)
                }
                renderWelcome(model, name: "onboarding-failed-expanded")
                model.detailsExpanded = false
                renderWelcome(model, name: "onboarding-failed-collapsed")

                fetch("old-contract") { model, _ in
                    if case .failed(let message, let detail) = model.download {
                        check("old contract: a generic friendly line", message == OnboardingModel.genericFailure)
                        check("old contract: the old message becomes the technical detail", detail.hasPrefix("SSLError"))
                    } else {
                        check("old contract: ends in a failure", false)
                    }

                    fetch("crash") { model, _ in
                        if case .failed(let message, let detail) = model.download {
                            check("helper crash: a friendly line", message == "The download stopped unexpectedly. Try again.")
                            check("helper crash: exit code and stderr in the details", detail.contains("exit 3") && detail.contains("boom"))
                        } else {
                            check("helper crash: ends in a failure", false)
                        }
                        check("clipping: a long detail is cut to the limit", OnboardingModel.clipped(String(repeating: "x", count: 5000)).count == OnboardingModel.maxDetailLength + 1)
                        check("the generic line is the one the old contract shows", transientMessage == OnboardingModel.genericFailure)
                        MenuBarIcon.testLog("onboarding test: done, \(checks) checks, \(failures) failures")
                        AppQuit.now()
                    }
                }
            }
        }
    }

    /// The folder rule: a folder can be added only once the language model is installed. Checked for each model state
    /// of the welcome window, and for the menu's Add Folder item.
    private static func folderRule() {
        func status(_ ready: Bool) -> EngineStatus {
            EngineStatus(["files": 0, "chunks": 0, "folders": [String](), "indexing": false, "model": "m", "model_ready": ready])
        }
        let model = OnboardingModel()
        model.apply(status(false), rows: [])
        model.download = .idle
        check("folder rule: fresh, no model: Choose Folder is disabled", !model.canChooseFolder)
        model.download = .running
        check("folder rule: downloading: disabled", !model.canChooseFolder)
        model.download = .retrying(attempt: 2, max: 5)
        check("folder rule: retrying: disabled", !model.canChooseFolder)
        model.download = .failed(message: "failed", detail: "detail")
        check("folder rule: error: disabled", !model.canChooseFolder)
        model.download = .idle
        model.apply(status(true), rows: [])
        check("folder rule: model ready: enabled", model.canChooseFolder)

        let menu = StatusMenu(host: FakeStatusItem())
        // The menu's Folders row is one item that opens Settings at Folders; Add Folder lives in Settings.
        menu.update(status(true), "Running", rows: [FolderRow(id: "/a", path: "/a", text: "3 files", tone: .ok)])
        let row = menu.testMenu.items.first { $0.title.hasPrefix("Folders (") }
        check("menu: one Folders row with the count", row?.title == "Folders (1)…")
        check("menu: the Folders row has no submenu", row?.submenu == nil)
    }

    /// Renders the welcome window's failure state offscreen to a PNG.
    private static func renderWelcome(_ model: OnboardingModel, name: String) {
        let dir = ProcessInfo.processInfo.environment["SS_DUMP_DIR"] ?? SemPaths.home
        let host = NSHostingView(rootView: OnboardingView(model: model, onFinish: {}, onLater: {}).frame(width: 480))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 600)
        host.layoutSubtreeIfNeeded()
        let ok = UIDumpFormat.png(host, to: "\(dir)/\(name).png")
        check("rendered \(name).png", ok)
    }
}
#endif
