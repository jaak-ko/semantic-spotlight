#if DEBUG
import AppKit
import SwiftUI

/// Test only (`--glass-capture-for-test <dir>`, with GLASS_APPEARANCE set): the real windows of the redesign, captured
/// by window id only (CGWindowListCreateImage with optionIncludingWindow). Never by screen rectangle: a screen capture
/// picks up whatever else is on the screen. The capture holds this window's own pixels; the desktop behind the glass is
/// not composited (the behind-window blur is not verified here).
enum GlassCaptureTests {
    @MainActor static func start(dir: String) {
        let dark = (ProcessInfo.processInfo.environment["GLASS_APPEARANCE"] ?? "light") == "dark"
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let mode = dark ? "dark" : "light"
        let search = SearchController(engine: EngineManager.shared, scope: FolderScope(defaults: MemoryPrefs()),
                                      defaults: MemoryPrefs())
        search.testSetResults((0..<3).map { Hit(id: "\($0)", path: "/fixture/notes/file-\($0).txt", score: 0.5,
                                                similarity: 0.9, snippet: "A snippet about the file, with a few words.") },
                              notice: "")
        var steps: [(String, () -> NSWindow?)] = [
            ("welcome", { OnboardingWindow.shared.show(); return OnboardingWindow.shared.testFrameView?.window }),
            ("settings", { SettingsWindow.shared.show(); return SettingsWindow.shared.testFrameView?.window }),
            ("search", { search.show(); return search.testPanel }),
        ]
        func next() {
            guard let (name, show) = steps.first else {
                MenuBarIcon.testLog("glass capture: done")
                AppQuit.now()
                return
            }
            steps.removeFirst()
            guard let window = show() else { next(); return }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.layoutIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Headless.moveOffScreen(window)   // off every display; the hide after show set alpha 0, so set it back
                window.alphaValue = 1
                capture(window, to: "\(dir)/capture-\(name)-\(mode).png")
                if name != "search" { window.orderOut(nil) } else { search.hide() }
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() }
    }

    /// The window's frame view (its content and titlebar) drawn into a bitmap at the display's scale. The window server
    /// does not render a window that is off every display, so the capture draws the views itself (no screen read).
    /// The behind-window blur of the glass is not part of this drawing.
    @MainActor static func capture(_ window: NSWindow, to path: String) {
        window.contentView?.superview?.layoutSubtreeIfNeeded()   // a window that was never ordered in lays out only on demand
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        guard let frame = window.contentView?.superview, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds),
              let data = { () -> Data? in frame.cacheDisplay(in: frame.bounds, to: rep); return rep.representation(using: .png, properties: [:]) }() else {
            MenuBarIcon.testLog("glass capture: no image for \(path)")
            return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        MenuBarIcon.testLog("glass capture: \(path)")
    }
}

extension GlassCaptureTests {
    /// Test only (`--surface-capture-for-test <dir>`, GLASS_APPEARANCE): every surface and state, one window at a time, each
    /// captured by its own window id (never by screen rectangle). Welcome states 1 to 4, Settings, the Uninstall and
    /// Diagnostics sheets (the sheet's own window), search results, search with no matches, and the scope popover.
    @MainActor static func startSurfaces(dir: String) {
        let dark = (ProcessInfo.processInfo.environment["GLASS_APPEARANCE"] ?? "light") == "dark"
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let mode = dark ? "dark" : "light"
        let hits = (0..<3).map { Hit(id: "\($0)", path: "/fixture/notes/file-\($0).txt", score: 0.5,
                                     similarity: 0.9, snippet: "A snippet about the file, with a few words.") }
        // The folder scope: two folders, so the popover can show all, some and none.
        let scope = FolderScope(defaults: MemoryPrefs())
        scope.reconcile(EngineStatus(["files": 9, "chunks": 30, "folders": ["/fixture/notes", "/fixture/projects"],
                                      "indexing": false, "model": "m", "model_ready": true,
                                      "folder_stats": [["path": "/fixture/notes", "files": 6], ["path": "/fixture/projects", "files": 3]]]))
        let search2 = SearchController(engine: EngineManager.shared, scope: scope, defaults: MemoryPrefs())
        var steps: [(String, () -> NSWindow?, (() -> Void)?)] = []
        func searchStep(_ name: String, _ notice: String, _ found: [Hit], popover: Bool = false) {
            steps.append((name, {
                UninstallModel.testStartsDone = false
                search2.show(); search2.testSetResults(found, notice: notice)
                if popover { search2.testOpenPopover() }
                return popover ? search2.testPopoverPanel : search2.testPanel
            }, nil))
        }
        searchStep("search-results", "", hits)
        searchStep("search-nomatches", "No matches", [])
        searchStep("search-notice-engine-not-running", "The engine is not running. Start it from the menu.", [])
        searchStep("search-notice-no-folders", "No folders selected", [])
        scope.setAll(included: true)
        searchStep("popover-all", "", hits, popover: true)
        scope.setAll(included: false)
        searchStep("popover-none", "", hits, popover: true)
        scope.setAll(included: true)
        scope.toggle("/fixture/projects")
        searchStep("popover-some", "", hits, popover: true)
        for (name, variant) in [("welcome-fresh", ""), ("welcome-downloading", ""), ("welcome-retrying", "retrying"),
                                ("welcome-error", "error"), ("welcome-cancelled", "cancelled"),
                                ("welcome-model-ready", ""), ("welcome-folder-indexing", "indexing"),
                                ("welcome-folder-done", "three")] {
            let n = name == "welcome-fresh" ? 1 : name == "welcome-model-ready" ? 3 : (name.hasPrefix("welcome-folder") ? 4 : 2)
            steps.append((name, { OnboardingWindow.shared.testSetState(n, variant: variant); OnboardingWindow.shared.show(); return OnboardingWindow.shared.testFrameView?.window }, nil))
        }
        for (name, n, variant, tab) in [("settings-general-model-missing", 1, "", SettingsTab.general),
                                         ("settings-general-ready", 3, "", .general),
                                         ("settings-folders-empty", 3, "", .folders),
                                         ("settings-folders-indexing", 4, "mixed", .folders),
                                         ("settings-folders-per-folder", 4, "per-folder", .folders),
                                         ("settings-general-failed", 2, "error", .general),
                                         ("settings-general-cancelled", 2, "cancelled", .general),
                                         ("settings-general-downloading", 2, "", .general),
                                         ("settings-general-retrying", 2, "retrying", .general),
                                         ("settings-advanced", 4, "mixed", .advanced)] {
            steps.append((name, { UninstallModel.testStartsDone = false; OnboardingWindow.shared.testSetState(n, variant: variant)
                SettingsWindow.shared.testReset(); SettingsWindow.shared.show(tab: tab); return SettingsWindow.shared.testFrameView?.window }, nil))
        }
        steps.append(("settings-uninstall-confirm", { UninstallModel.testStartsDone = false; SettingsWindow.shared.testReset(); SettingsWindow.shared.show(open: .uninstall, tab: .advanced); return SettingsWindow.shared.testFrameView?.window }, nil))
        // The uninstall result: everything removed, some items left, and the working state (spinner and message).
        for (name, variant) in [("settings-uninstall-summary", "removed"), ("settings-uninstall-partial", "partial"),
                                ("settings-uninstall-working", "working")] {
            steps.append((name, { UninstallModel.testStartsDone = true; UninstallModel.testVariant = variant
                SettingsWindow.shared.testReset(); SettingsWindow.shared.show(open: .uninstall, tab: .advanced); return SettingsWindow.shared.testFrameView?.window }, nil))
        }
        steps.append(("settings-diagnostics", { UninstallModel.testStartsDone = false; SettingsWindow.shared.testReset(); SettingsWindow.shared.show(open: .diagnostics, tab: .advanced); return SettingsWindow.shared.testFrameView?.window }, nil))
        // GLASS_ONLY=<name> captures one surface in its own process (a window that a previous capture hid is not shown again).
        if let only = ProcessInfo.processInfo.environment["GLASS_ONLY"], !only.isEmpty { steps = steps.filter { $0.0 == only } }
        func next() {
            guard !steps.isEmpty else {
                MenuBarIcon.testLog("surface capture: done")
                AppQuit.now()
                return
            }
            let (name, show, _) = steps.removeFirst()
            guard let window = show() else { MenuBarIcon.testLog("surface capture: no window for \(name)"); next(); return }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.layoutIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                // A sheet is its own window: capture it by its own id (the parent is the window it is attached to).
                let isSheet = name.contains("uninstall") || name.contains("diagnostics")
                let target = isSheet ? (window.attachedSheet ?? window) : window
                if isSheet, window.attachedSheet == nil { MenuBarIcon.testLog("surface capture: \(name) has no attached sheet") }
                Headless.moveOffScreen(target)   // off every display, no activation; the window server still renders it
                target.alphaValue = 1

                capture(target, to: "\(dir)/\(name)-\(mode).png")
                window.orderOut(nil)
                if name.hasPrefix("search") || name.hasPrefix("popover") { search2.hide() }
                next()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() }
    }
}
#endif
