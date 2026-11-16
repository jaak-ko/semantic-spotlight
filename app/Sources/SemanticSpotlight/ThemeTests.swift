#if DEBUG
import AppKit
import SwiftUI

/// Test only (`--theme-test-for-test <dir>`, test roots, headless): the contrast of every token pair the surfaces use, in
/// light and dark, asserted against WCAG AA (4.5:1 text, 3:1 for UI). Then every surface and state is rendered offscreen
/// to PNG in both appearances, for review. Nothing is shown.
enum ThemeTests {
    /// The render mode of the surfaces: the glass, or the solid fallback (Reduce Transparency). Set by `run`.
    private static var solid = false

    private static func png(_ view: NSView, _ dir: String, _ name: String, dark: Bool) {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        _ = UIDumpFormat.png(view, to: "\(dir)/\(name)\(solid ? "-solid" : "")-\(dark ? "dark" : "light").png")
    }

    private static func host<V: View>(_ view: V, width: CGFloat) -> NSView {
        let h = NSHostingView(rootView: AnyView(view.environment(\.solidGlassForTest, solid)))
        h.frame = NSRect(x: 0, y: 0, width: width, height: 100)
        h.layoutSubtreeIfNeeded()
        h.setFrameSize(NSSize(width: width, height: max(h.fittingSize.height, 40)))
        h.layoutSubtreeIfNeeded()
        return h
    }

    /// Pixels of an offscreen render that are the success colour, in the given appearance (the done marks are green).
    private static func successPixels(_ view: NSView, dark: Bool) -> Int {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return 0 }
        view.cacheDisplay(in: view.bounds, to: rep)
        var target = NSColor.black
        (NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            target = Theme.successNS.usingColorSpace(.sRGB) ?? target
        }
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                if abs(c.redComponent - target.redComponent) < 0.05, abs(c.greenComponent - target.greenComponent) < 0.05,
                   abs(c.blueComponent - target.blueComponent) < 0.05 { n += 1 }
            }
        }
        return n
    }

    /// The menu's width for short and long folder paths and a busy engine. Logged for the width report; the menu is
    /// measured as it is built (NSMenu.size), which is what the status item shows.
    static func menuWidths() {
        let long = "/Users/fixture/Documents/Projects/Client Archive 2024/Deliverables/Final Versions/Round Three/"
            + "Contracts and Scans/2019-2024 Original Documents/Nested Folder With A Very Long Name"
        let cases: [(String, [FolderRow], EngineStatus)] = [
            ("short", [FolderRow(id: "/a", path: "/Users/fixture/notes", text: "Done: 6 files indexed", tone: .ok)],
             EngineStatus(["files": 6, "chunks": 40, "model": "m", "model_ready": true, "indexing": false])),
            ("long", [FolderRow(id: long, path: long, text: "Done: 6 files indexed", tone: .ok),
                      FolderRow(id: "/b", path: "/Users/fixture/work", text: "Failed to add: \(long)", tone: .error)],
             EngineStatus(["files": 6, "chunks": 40, "model": "m", "model_ready": true, "indexing": false])),
            ("long, busy", [FolderRow(id: long, path: long, text: "Indexing…", tone: .busy)],
             EngineStatus(["files": 6, "chunks": 40, "model": "m", "model_ready": true, "indexing": true])),
            ("real content", [FolderRow(id: "/a", path: "/Users/fixture/notes", text: "Indexing…", tone: .busy),
                             FolderRow(id: "/b", path: "/Users/fixture/work", text: "Done: 6 files indexed", tone: .ok)],
             EngineStatus(["files": 1284, "chunks": 9120, "model": "intfloat/multilingual-e5-small", "model_ready": true,
                           "indexing": true, "done": 62, "total": 100, "phase": "embed"]))
        ]
        for (name, rows, status) in cases {
            let menu = StatusMenu(host: FakeStatusItem())
            menu.update(status, "Ready", rows: rows)
            menu.updateProgress(status)
            MenuBarIcon.testLog("menu width \(name): \(String(format: "%.0f", Double(menu.testMenu.size.width))) pt")
        }
    }

    @MainActor static func run(dir: String) {
        menuWidths()
        var failures = Headless.screenGuard("theme test start")
        failures += GlassContrastTests.run(dir: dir)
        failures += SelectionTests.run()
        failures += ButtonTests.run(dir: dir)
        failures += OnboardingStateTests.run()
        for pair in Theme.contrastPairs {
            for dark in [false, true] {
                let r = Theme.ratio(pair.text, pair.background, dark: dark)
                let ok = pair.minimum == 0 || r >= pair.minimum
                if !ok { failures += 1 }
                MenuBarIcon.testLog("theme contrast: \(pair.name) \(dark ? "dark" : "light") \(String(format: "%.2f", Double(r)))\(pair.minimum > 0 ? " (min \(pair.minimum))" : " (decorative)") \(ok ? "ok" : "FAIL")")
            }
        }
        // The surfaces, each in light and dark, with the glass and with the solid fallback (Reduce Transparency).
        for solidMode in [false, true] {
        solid = solidMode
        let scope = FolderScope(defaults: MemoryPrefs())
        scope.reconcile(EngineStatus(["files": 9, "chunks": 40, "folders": ["/fixture/notes", "/fixture/work"], "indexing": false,
                                      "model": "m", "model_ready": true, "folder_stats": [["path": "/fixture/notes", "files": 6],
                                                                                          ["path": "/fixture/work", "files": 3]]]))
        let engine = EngineManager.shared
        let search = SearchModel(engine: engine, scope: scope)
        let hits = (0..<3).map { Hit(id: "\($0)", path: "/fixture/notes/file-\($0).txt", score: 0.5,
                                     similarity: [0.9, 0.8, 0.72][$0], snippet: "A snippet about the file, with a few words.") }
        search.testSetResults(hits, notice: "")
        for dark in [false, true] {
            png(host(SearchView(model: search, scope: scope).frame(width: 640), width: 640), dir, "surface-search-3-results", dark: dark)
        }
        let empty = SearchModel(engine: engine, scope: scope)
        empty.testSetResults([], notice: "No good matches")
        for dark in [false, true] {
            png(host(SearchView(model: empty, scope: scope).frame(width: 640), width: 640), dir, "surface-search-no-matches", dark: dark)
            png(host(FolderPopoverView(model: search, scope: scope, onHover: { _ in }), width: 320), dir, "surface-folder-list", dark: dark)
            png(host(HintRow().frame(width: 640).background(Theme.panel), width: 640), dir, "surface-hint-row", dark: dark)
            // The folder list's All and None: one folder left out (both enabled), then all left out (None disabled).
            for (name, leftOut) in [("surface-folder-list-some", ["/fixture/work"]), ("surface-folder-list-none", ["/fixture/notes", "/fixture/work"])] {
                let some = FolderScope(defaults: MemoryPrefs())
                some.reconcile(EngineStatus(["files": 9, "chunks": 40, "folders": ["/fixture/notes", "/fixture/work"], "indexing": false,
                                             "model": "m", "model_ready": true, "folder_stats": [["path": "/fixture/notes", "files": 6],
                                                                                                 ["path": "/fixture/work", "files": 3]]]))
                leftOut.forEach { some.toggle($0) }
                let model = SearchModel(engine: engine, scope: some)
                png(host(FolderPopoverView(model: model, scope: some, onHover: { _ in }), width: 320), dir, name, dark: dark)
            }
        }
        for dark in [false, true] {
            let fresh = OnboardingModel()
            let freshView = host(OnboardingView(model: fresh, onFinish: {}, onLater: {}).frame(width: 480), width: 480)
            png(freshView, dir, "surface-welcome-fresh", dark: dark)
            let done = OnboardingModel()
            done.apply(EngineStatus(["files": 6, "chunks": 20, "folders": ["/fixture/notes"], "indexing": false, "model": "m",
                                     "model_ready": true, "folder_stats": [["path": "/fixture/notes", "files": 6]]]),
                       rows: [FolderRow(id: "/fixture/notes", path: "/fixture/notes", text: "Done: 6 files indexed", tone: .ok)])
            let doneView = host(OnboardingView(model: done, onFinish: {}, onLater: {}).frame(width: 480), width: 480)
            png(doneView, dir, "surface-welcome-ready-done", dark: dark)
            let greenDone = successPixels(doneView, dark: dark)
            let greenFresh = successPixels(freshView, dark: dark)
            MenuBarIcon.testLog("theme: success pixels, ready and done \(greenDone), fresh \(greenFresh) (\(dark ? "dark" : "light"))")
            if greenDone < 40 || greenFresh != 0 { failures += 1 }
            let failed = OnboardingModel()
            failed.download = .failed(message: "Could not reach the model server. Check the network connection, then try again.",
                                      detail: "SSLError: MaxRetryError(\"HTTPSConnectionPool(host='huggingface.co', port=443)\")")
            failed.detailsExpanded = true
            png(host(OnboardingView(model: failed, onFinish: {}, onLater: {}).frame(width: 480), width: 480), dir, "surface-welcome-error", dark: dark)
            let retrying = OnboardingModel()
            retrying.download = .retrying(attempt: 2, max: 5)
            png(host(OnboardingView(model: retrying, onFinish: {}, onLater: {}).frame(width: 480), width: 480), dir, "surface-welcome-retrying", dark: dark)
            png(host(SettingsView(nav: SettingsNav.shared, welcome: OnboardingModel()).frame(width: 460), width: 460), dir, "surface-settings", dark: dark)
            png(host(UninstallSheet(model: UninstallModel(), close: {}).frame(width: 460), width: 460), dir, "surface-uninstall-sheet", dark: dark)
            png(host(DiagnosticsSheet(model: DiagnosticsModel(), close: {}).frame(width: 460), width: 460), dir, "surface-diagnostics-sheet", dark: dark)
        }
        }
        WindowLookTests.render(dir: dir)
        failures += HintRowTests.run(dir: dir)
        failures += ProgressTests.run()
        let end = Headless.screenGuard("theme test end")   // no window of the app may be on a display (SS_HEADLESS=1)
        failures += end
        MenuBarIcon.testLog("theme: \(failures) contrast failure(s)")
        MenuBarIcon.testLog("theme test: done, \(failures) failures")
        AppQuit.now()
    }
}
#endif
