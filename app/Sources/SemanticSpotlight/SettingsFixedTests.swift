#if DEBUG
import AppKit

/// Test only (run by the theme test): Settings has one fixed size. (1) Six tab switches: the window's frame is identical
/// before and after each, no frame change is asked of the window during a switch (the spy counts them), and the top strip
/// (the titlebar, 28 pt) has the same pixels before and after. (2) Each tab fits the fixed tab area at two folders, the
/// folder list stays the same height with thirty folders, and a tab taller than the area scrolls inside it.
enum SettingsFixedTests {
    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("settings fixed: \(ok ? "ok" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
        }
        func settle(_ s: TimeInterval = 0.25) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
        /// The top 28 pt of the window's frame view, as bytes (the titlebar strip, rendered).
        func topStrip(_ view: NSView) -> Data? {
            let rect = NSRect(x: 0, y: view.bounds.height - 28, width: view.bounds.width, height: 28)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
            view.cacheDisplay(in: rect, to: rep)
            guard let bytes = rep.bitmapData else { return nil }
            return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
        }

        // Two folders listed, as on the user's Mac: the sizes the app measures.
        let two = ["/fixture/notes", "/fixture/projects"].map { FolderRow(id: $0, path: $0, text: "6 files", tone: .ok) }
        OnboardingWindow.shared.model.apply(nil, rows: two)
        SettingsWindow.shared.testReset()
        SettingsWindow.shared.show(tab: .general)
        settle()
        guard let window = SettingsWindow.shared.testWindow, let frameView = window.contentView?.superview else {
            check("the Settings window exists", false); return failures
        }
        let screen = window.screen ?? NSScreen.main
        let windowSize = SettingsLayout.windowSize(for: screen)
        check("the window is the fixed size (tallest tab at two folders, within the screen)",
              window.frame.size == windowSize && windowSize.height <= SettingsLayout.maxWindowHeight(screen),
              "frame \(window.frame.size) vs \(windowSize)")

        // (1) Six tab switches.
        let switches: [SettingsTab] = [.folders, .advanced, .general, .folders, .advanced, .general]
        for (i, tab) in switches.enumerated() {
            let frameBefore = window.frame
            let topBefore = topStrip(frameView)
            let changesBefore = AppWindow.frameChanges
            SettingsWindow.shared.select(tab)
            settle()
            let changes = AppWindow.frameChanges - changesBefore
            check("switch \(i + 1) to \(tab.title): the frame is identical", window.frame == frameBefore, "\(window.frame) vs \(frameBefore)")
            check("switch \(i + 1) to \(tab.title): no frame change is asked of the window", changes == 0, "\(changes) changes")
            check("switch \(i + 1) to \(tab.title): the top strip has the same pixels",
                  topBefore != nil && topStrip(frameView) == topBefore)
        }

        // (2) Fit and scroll: every tab and every General state fits the area at two folders.
        let area = SettingsLayout.contentHeight(for: screen)
        for tab in [SettingsTab.folders, .advanced] {
            let natural = SettingsLayout.naturalTabHeight(tab)
            check("\(tab.title) fits the fixed tab area at two folders", !SettingsLayout.overflows(natural: natural, area: area),
                  "natural \(Int(natural)), area \(Int(area))")
            MenuBarIcon.testLog("settings fixed: \(tab.title) natural height \(Int(natural)) pt at two folders, area \(Int(area)) pt")
        }
        var readyHeight: CGFloat = 0
        var otherHeights: [CGFloat] = []
        for state in SettingsLayout.generalStates() {
            let natural = SettingsLayout.naturalTabHeight(.general, welcome: state.model)
            if state.name == "ready" { readyHeight = natural } else { otherHeights.append(natural) }
            check("General (\(state.name)) fits the fixed tab area at two folders", !SettingsLayout.overflows(natural: natural, area: area),
                  "natural \(Int(natural)), area \(Int(area))")
            MenuBarIcon.testLog("settings fixed: General \(state.name) natural height \(Int(natural)) pt, area \(Int(area)) pt")
        }
        check("the ready row reserves no room for the other states (it is the shortest)", readyHeight <= (otherHeights.min() ?? 0) + 0.5,
              "ready \(Int(readyHeight)) pt")
        let twoFolders = SettingsLayout.naturalTabHeight(.folders)
        OnboardingWindow.shared.model.apply(nil, rows: (0..<30).map { FolderRow(id: "/f/\($0)", path: "/fixture/folder-\($0)", text: "6 files", tone: .ok) })
        let thirtyFolders = SettingsLayout.naturalTabHeight(.folders)
        check("thirty folders: the Folders tab keeps its height (the list scrolls inside its area)", abs(thirtyFolders - twoFolders) < 0.5,
              "\(Int(twoFolders)) vs \(Int(thirtyFolders))")
        check("a tab taller than its area is reported to scroll", SettingsLayout.overflows(natural: 600, area: 500))
        check("a tab that fits its area is not reported to scroll", !SettingsLayout.overflows(natural: 500, area: 520))
        OnboardingWindow.shared.model.apply(nil, rows: [])
        check("the crossfade is 0.12 s", SettingsLayout.crossfade == 0.12)

        SettingsWindow.shared.testReset()
        SettingsNav.shared.setTab(.general)
        return failures
    }
}
#endif
