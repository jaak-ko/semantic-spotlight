import AppKit

/// SS_HEADLESS=1 (set by tools/testlib.sh for every check): the app puts nothing on the user's screen. No status item
/// is created, windows are transparent and far off-screen, and the app never activates. Tests drive the same code
/// paths against a fake menu-bar host and an off-screen window. Nothing in the normal app reads this.
enum Headless {
    #if DEBUG
    static var enabled: Bool { ProcessInfo.processInfo.environment["SS_HEADLESS"] == "1" }
    #else
    static var enabled: Bool { false }
    #endif

    /// Transparent and far off-screen; still a real window, so sheets and the window list keep working.
    static func hide(_ window: NSWindow) {
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    }

    /// Tests and test captures: the window is moved fully off every display. It is NOT ordered front: a capture draws the
    /// window's views (cacheDisplay), so no window is ever put on a screen by a test. (Ordering it front made macOS move
    /// the window back onto a display, which is how a test window reached the user's screen.)
    static func moveOffScreen(_ window: NSWindow) {
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    }

    /// The watchdog: a repeating check on the main run loop for the whole run. Any window of the app with alpha above 0
    /// whose frame meets a display fails the run at once (the log says which window).
    private static var watchdogTimer: Timer?
    static var watchdogSuspended = false
    static func startWatchdog() {
        #if DEBUG
        guard enabled, watchdogTimer == nil else { return }
        // A sheet is its own window, placed by AppKit on the screen when its parent is off every display. Headless runs
        // make every sheet transparent and move it off every display as soon as AppKit updates it.
        NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let w = note.object as? NSWindow, w.sheetParent != nil else { return }
                if w.alphaValue > 0 || w.frame.origin.x > -20000 { hide(w) }
            }
        }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                if watchdogSuspended { return }   // only the guard's own self-test suspends it
                if screenGuard("watchdog") > 0 {
                    MenuBarIcon.testLog("headless watchdog: FAIL, a window of the app is on a display; the run stops")
                    exit(1)
                }
            }
        }
        #endif
    }

    /// A window offends when it is on the screen (ordered in, so it can be seen) with alpha above 0 and its frame meets a
    /// display. An unordered window cannot reach a display until it is ordered in, and the watchdog polls for that.
    static func offends(frame: NSRect, alpha: CGFloat, visible: Bool, screens: [NSRect]) -> Bool {
        visible && alpha > 0 && screens.contains(where: { $0.intersects(frame) })
    }

    /// The headless guard, run at the start and end of a test run: no window of the app may intersect a display.
    /// Returns the number of windows that do (each is logged). Only checked under SS_HEADLESS=1.
    @MainActor static func screenGuard(_ label: String) -> Int {
#if DEBUG
        guard enabled else { return 0 }
        let screens = NSScreen.screens.map { $0.frame }
        var found = 0
        // A window with alpha 0 draws nothing; the search panel keeps its place on the display (the scope test checks it)
        // and is transparent under SS_HEADLESS. Any other window of the app on a display fails the check.
        for w in NSApp.windows where Headless.offends(frame: w.frame, alpha: w.alphaValue, visible: w.isVisible, screens: screens) {
            found += 1
            MenuBarIcon.testLog("headless guard (\(label)): \(type(of: w)) at \(w.frame) alpha \(w.alphaValue) "
                                + "sheet \(w.sheetParent != nil) visible \(w.isVisible) title '\(w.title)' "
                                + "content \(w.contentView.map { String(describing: type(of: $0)) } ?? "none") is on a display")
        }
        return found
#else
        return 0
#endif
    }

    /// Transparent, in place: for a window whose position a test checks.
    static func makeInvisible(_ window: NSWindow) {
        window.alphaValue = 0
    }

    /// Hides every window of the app, now and shortly after. SwiftUI sheets and resizing move windows after they
    /// are shown, so one hide is not enough. Sheets follow their parent, so the sheets are covered too.
    static func hideAllWindows() {
        guard enabled else { return }
        for window in NSApp.windows { hide(window) }
    }

    static func hideAllSoon() {
        guard enabled else { return }
        for delay in [0.0, 0.1, 0.5, 1.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { hideAllWindows() }
        }
    }
}

/// Where the status menu attaches its menu: the real status item, or a fake one in headless runs and tests.
protocol MenuBarHost: AnyObject {
    var menu: NSMenu? { get set }
    var button: NSStatusBarButton? { get }
}

extension NSStatusItem: MenuBarHost {}

/// A status item that is never shown. It counts how often a menu is attached, so tests can prove it stays at one.
final class FakeStatusItem: MenuBarHost {
    private(set) var menuAssignments = 0
    var menu: NSMenu? {
        didSet { menuAssignments += 1 }
    }
    var button: NSStatusBarButton? { nil }
}

/// The app's windows. Under SS_HEADLESS a window is never constrained back onto a display: macOS moves a titled window
/// that is ordered front off every screen back onto a screen (usually the bottom left). The override keeps the frame the
/// test asked for. Outside headless runs the frame is constrained as usual.
final class AppWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        Headless.enabled ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
#if DEBUG
    /// Test only: every frame change asked of an app window (a spy). A Settings tab switch must make none.
    static var frameChanges = 0
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        AppWindow.frameChanges += 1
        super.setFrame(frameRect, display: flag)
    }
    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        AppWindow.frameChanges += 1
        super.setFrame(frameRect, display: displayFlag, animate: animateFlag)
    }
#endif
}

/// No control has focus when a window or sheet first opens: no focus ring or glow. Keyboard use (Tab, arrows) brings
/// the focus ring, as on the welcome's buttons; the search field takes its caret when it is typed into.
func clearInitialFocus(_ window: NSWindow?) {
    guard let window else { return }
    window.initialFirstResponder = nil
    window.makeFirstResponder(nil)
}

/// Sheets of the app (Uninstall, Diagnostics): no control has the focus when a sheet opens, so no focus ring or glow shows.
/// Each sheet is cleared once, when AppKit first updates it; the user's own Tab moves focus after that.
@MainActor private var clearedSheets = Set<ObjectIdentifier>()
@MainActor func installSheetFocusRule() {
    NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
        MainActor.assumeIsolated {
            guard let w = note.object as? NSWindow, w.sheetParent != nil else { return }
            guard clearedSheets.insert(ObjectIdentifier(w)).inserted else { return }
            clearInitialFocus(w)
        }
    }
}
