#if DEBUG
import AppKit

/// Test only (`--chrome-test-for-test`, test roots): the real titled windows of the app (the welcome window and Settings),
/// as the app creates them, checked the way a user meets them: the traffic-light buttons (present, placed, enabled,
/// hit-testable, closing), and the top area (draggable, and it reads as a bar).
enum ChromeTests {
    static var failures = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        MenuBarIcon.testLog("chrome test: \(ok ? "ok" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
    }

    /// The window's frame view (the titlebar and the content, as AppKit lays them out) and a point in it.
    static func frameView(_ w: NSWindow) -> NSView? { w.contentView?.superview }

    static func describe(_ view: NSView?) -> String {
        guard let view else { return "nil" }
        return String(describing: type(of: view))
    }

    /// Runs the checks on one window. `closes` says the window is expected to close from its close button.
    static func run(_ name: String, _ w: NSWindow) {
        Headless.moveOffScreen(w)
        w.layoutIfNeeded()
        // On open no control has the focus, so no focus ring or glow shows (the ring is for Tab and arrow keys).
        let focused = w.firstResponder
        check("\(name): no control has the focus when the window opens", !(focused is NSControl), "first responder \(focused.map { String(describing: type(of: $0)) } ?? "none")")
        guard let frame = frameView(w) else { check("\(name): frame view exists", false); return }
        frame.layoutSubtreeIfNeeded()
        for (label, kind) in [("close", NSWindow.ButtonType.closeButton), ("minimise", .miniaturizeButton), ("zoom", .zoomButton)] {
            guard let b = w.standardWindowButton(kind) else { check("\(name): \(label) button exists", false); continue }
            let inFrame = b.convert(b.bounds, to: frame)
            check("\(name): \(label) button is visible", !b.isHidden && b.alphaValue > 0.5 && inFrame.width > 0,
                  "frame \(Int(inFrame.minX)),\(Int(inFrame.minY)) \(Int(inFrame.width))x\(Int(inFrame.height)), superview \(describe(b.superview))")
            // Minimise works. Zoom is disabled on purpose: these windows are not resizable, and a disabled zoom looks disabled.
            let expectEnabled = kind != .zoomButton
            check("\(name): \(label) button is \(expectEnabled ? "enabled" : "disabled")", b.isEnabled == expectEnabled)
            let centre = NSPoint(x: inFrame.midX, y: inFrame.midY)
            let hit = frame.hitTest(centre)
            let underButton = hit.map { v in sequence(first: v as NSView?, next: { $0?.superview }).contains { $0 === b } } ?? false
            check("\(name): the \(label) button is the hit view at its centre", underButton,
                  "hit \(describe(hit))")
        }
        check("\(name): the window is movable by its background (the titlebar strip drags it)", w.isMovableByWindowBackground)
        check("\(name): the window can be minimised", w.styleMask.contains(.miniaturizable))
        if let c = w.contentView {
            MenuBarIcon.testLog("chrome geometry \(name): window \(w.frame) content \(c.frame) contentLayout \(w.contentLayoutRect) safeTop \(c.safeAreaInsets.top) styleMask \(w.styleMask.rawValue) fullSize \(w.styleMask.contains(.fullSizeContentView)) hostingIsContentView true")
        }
        // The top area, a point in the middle of the titlebar strip, not on a button: a drag there moves the window.
        let top = NSPoint(x: frame.bounds.midX, y: frame.bounds.maxY - 12)
        let topHit = frame.hitTest(top)
        let canMove = topHit.map { v in v.mouseDownCanMoveWindow || w.isMovableByWindowBackground } ?? false
        check("\(name): the top area is draggable", canMove, "hit \(describe(topHit)) movable-by-background \(w.isMovableByWindowBackground)")
    }

    /// Clicks the close button of the real window and checks it closes.
    static func closeCheck(_ name: String, _ w: NSWindow) {
        guard let b = w.standardWindowButton(.closeButton) else { return }
        b.performClick(nil)
        check("\(name): close button closes the window", !w.isVisible)
    }

    @MainActor static func start() {
        SettingsWindow.shared.show()
        OnboardingWindow.shared.show()
        DispatchQueue.main.async {
            if let w = SettingsWindow.shared.testFrameView?.window { run("settings", w) }
            if let w = OnboardingWindow.shared.testFrameView?.window { run("welcome", w) }
            if let w = SettingsWindow.shared.testFrameView?.window { closeCheck("settings", w) }
            if let w = OnboardingWindow.shared.testFrameView?.window { closeCheck("welcome", w) }
            // Sheets and the scope popover: no control has the focus on open. Checked after they have appeared.
            SettingsWindow.shared.testReset()
            SettingsWindow.shared.show(open: .uninstall)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                sheetFocus("uninstall sheet")
                SettingsWindow.shared.testReset()
                SettingsWindow.shared.show(open: .diagnostics)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    sheetFocus("diagnostics sheet")
                    SettingsWindow.shared.testReset()
                    let search = SearchController(engine: EngineManager.shared, scope: FolderScope(defaults: MemoryPrefs()),
                                                  defaults: MemoryPrefs())
                    search.show()
                    search.testOpenPopover()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        if let p = search.testPopoverPanel {
                            check("scope popover: no control has the focus when it opens", !(p.firstResponder is NSControl),
                                  "first responder \(p.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
                        } else { check("scope popover opened", false) }
                        search.hide()
                        failures += Headless.screenGuard("chrome test end")   // no window of the app may be on a display
                        MenuBarIcon.testLog("chrome test: done, \(failures) failure(s)")
                        AppQuit.now()
                    }
                }
            }
        }
    }

    /// A sheet of the Settings window: attached, and no control holds the focus.
    @MainActor static func sheetFocus(_ name: String) {
        guard let sheet = SettingsWindow.shared.testFrameView?.window?.attachedSheet else {
            check("\(name) is attached to the window", false)
            return
        }
        check("\(name): no control has the focus when it opens", !(sheet.firstResponder is NSControl),
              "first responder \(sheet.firstResponder.map { String(describing: type(of: $0)) } ?? "none")")
    }
}
#endif
