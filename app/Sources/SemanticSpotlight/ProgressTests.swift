#if DEBUG
import AppKit
import SwiftUI

/// Test only (run by the theme test): the download's progress does not disturb the window. (1) 200 ticks of progress
/// through the throttle: the publishes stay at 4 a second or fewer, the window's frame never changes, the titlebar and the
/// traffic lights keep their views, are never hidden, and each tick costs little time on the main thread. (2) The progress
/// line has one width for every pair of values (monospaced digits in a fixed slot), so it never reflows.
enum ProgressTests {
    /// The window's glass under a height animation: at 20 steps of a Settings change the blur and the tint cover the whole
    /// frame view (titlebar included), and the top 28 pt strip of the rendered frame view is never see-through.
    @MainActor static func glassCoverageTest() -> Int {
        var failures = 0
        var violations: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1; violations.append("\(name)\(detail.isEmpty ? "" : " (\(detail))")") }
        }
        SettingsWindow.shared.testReset()
        SettingsWindow.shared.show(tab: .general)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        guard let window = SettingsWindow.shared.testFrameView?.window, let frameView = window.contentView?.superview else {
            check("the Settings window exists", false); return failures
        }
        let blur = frameView.subviews.first { $0.identifier == WindowGlass.blurID }
        let tint = frameView.subviews.first { $0.identifier == WindowGlass.tintID }
        check("the window glass is installed (blur and tint)", blur != nil && tint != nil)
        var samples = 0
        // Six tab switches. The window does not resize, so the glass only has to cover the frame view at every sampled
        // moment of the crossfade (the content changes, the glass does not), and the top strip stays opaque.
        for tab in [SettingsTab.folders, .advanced, .general, .folders, .advanced, .general] {
            SettingsWindow.shared.select(tab)
            for _ in 0..<5 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
                samples += 1
                let bounds = frameView.bounds
                check("glass covers the frame view during a tab switch (blur)", blur.map { $0.frame == bounds } ?? false,
                      "\(String(describing: blur?.frame)) vs \(bounds)")
                check("glass covers the frame view during a tab switch (tint)", tint.map { $0.frame == bounds } ?? false)
                // The rendered top 28 pt strip is never see-through: every sampled pixel is at least partly opaque.
                if let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) {
                    frameView.cacheDisplay(in: bounds, to: rep)
                    let scale = CGFloat(rep.pixelsWide) / max(bounds.width, 1)
                    let rows = Int(28 * scale)
                    var minAlpha: CGFloat = 1
                    for y in stride(from: 0, to: min(rows, rep.pixelsHigh), by: 4) {
                        for x in stride(from: 0, to: rep.pixelsWide, by: 16) {
                            minAlpha = min(minAlpha, rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                        }
                    }
                    check("the top 28 pt strip is not see-through", minAlpha >= 0.9, "min alpha \(String(format: "%.2f", minAlpha))")
                } else {
                    check("the frame view renders", false)
                }
            }
        }
        MenuBarIcon.testLog("glass coverage: \(samples) steps, \(violations.count) violation(s)")
        for v in violations.prefix(4) { MenuBarIcon.testLog("glass coverage violation: \(v)") }
        SettingsWindow.shared.testReset()
        return failures
    }

    /// The welcome page's height change (the only window that still resizes): sampled at 60 steps over 0.3 s. The top
    /// edge, the x origin and the traffic lights never move, the height goes monotonically from old to new with no
    /// overshoot, and Reduce Motion is one step. Settings has no height change (SettingsFixedTests).
    @MainActor static func windowMotionTest() -> Int {
        var failures = 0
        var violations: [String] = []
        var samples = 0
        var switches = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1; violations.append("\(name)\(detail.isEmpty ? "" : " (\(detail))")") }
        }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }

        /// Drives one change through its sampled steps on `window`, checking every step.
        func drive(_ window: NSWindow, to target: NSRect, label: String, reduceMotion: Bool = false) {
            let from = window.frame
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
            let startRects = buttons.map { window.convertToScreen($0.convert($0.bounds, to: nil)) }
            let steps = WindowMotion.sequence(from: from, to: target, over: 0.3, samples: 60, reduceMotion: reduceMotion)
            var heights: [CGFloat] = []
            for f in steps {
                window.setFrame(f, display: false)
                samples += 1
                heights.append(f.height)
                check("\(label): the top edge never moves", abs(f.maxY - from.maxY) < 0.5, "\(f.maxY) vs \(from.maxY)")
                check("\(label): the window x never moves", abs(f.minX - from.minX) < 0.5)
                for (i, b) in buttons.enumerated() {
                    check("\(label): traffic light \(i) is not hidden", b.isHidden == false)
                    check("\(label): traffic light \(i) has alpha 1", b.alphaValue == 1, "\(b.alphaValue)")
                    let r = window.convertToScreen(b.convert(b.bounds, to: nil))
                    check("\(label): traffic light \(i) keeps its frame", r == startRects[i], "\(r) vs \(startRects[i])")
                }
            }
            let lo = min(from.height, target.height), hi = max(from.height, target.height)
            check("\(label): no overshoot", heights.allSatisfy { $0 >= lo - 0.01 && $0 <= hi + 0.01 })
            let up = target.height >= from.height
            let monotonic = zip(heights, heights.dropFirst()).allSatisfy { up ? $1 >= $0 - 0.01 : $1 <= $0 + 0.01 }
            check("\(label): the height changes monotonically", monotonic)
            check("\(label): it ends at the target", steps.last == target)
            switches += 1
        }

        // The welcome page's height change: the same helper.
        OnboardingWindow.shared.testSetState(1)
        OnboardingWindow.shared.show()
        settle()
        OnboardingWindow.shared.fitToContent(animated: false)
        if let welcome = OnboardingWindow.shared.testFrameView?.window, let to = OnboardingWindow.shared.contentTargetFrame() {
            OnboardingWindow.shared.testSetState(4, variant: "three")
            if let grown = OnboardingWindow.shared.contentTargetFrame() {
                welcome.setFrame(welcome.frame, display: false)
                drive(welcome, to: grown, label: "welcome grows")
            }
            _ = to
        } else {
            check("the welcome window exists", false)
        }
        MenuBarIcon.testLog("window motion: \(switches) changes, \(samples) sampled steps, \(violations.count) violation(s)")
        for v in violations.prefix(5) { MenuBarIcon.testLog("window motion violation: \(v)") }
        return failures
    }


    /// Settings as tabs: one fixed size for every tab, within the display's visible height minus 80; the traffic lights
    /// survive a tab switch; a 30-folder list stays inside its area; the menu's Folders row opens the Folders tab.
    @MainActor static func settingsTabsTest() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("settings tabs: \(ok ? "ok" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
        }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
        let screenLimit = (NSScreen.main?.visibleFrame.height ?? 800) - 80
        SettingsWindow.shared.testReset()
        SettingsWindow.shared.show(tab: .general)
        settle()
        guard let window = SettingsWindow.shared.testFrameView?.window else { check("settings window exists", false); return failures }
        let close = window.standardWindowButton(.closeButton)
        let fixedHeight = window.frame.height
        for tab in SettingsTab.allCases {
            SettingsWindow.shared.select(tab)
            settle()
            check("\(tab.title) tab: the window keeps the fixed height and stays within the screen minus 80",
                  window.frame.height == fixedHeight && fixedHeight <= screenLimit, "height \(Int(window.frame.height))")
        }
        check("the traffic lights survive a tab switch", window.standardWindowButton(.closeButton) === close && (close?.isHidden == false))
        // Thirty folders: the list scrolls inside its area, so the window stays within the limit.
        let thirty = (0..<30).map { FolderRow(id: "/f/\($0)", path: "/fixture/folder-\($0)", text: "6 files", tone: .ok) }
        OnboardingWindow.shared.model.apply(nil, rows: thirty)
        SettingsWindow.shared.select(.folders)
        settle()
        check("30 folders: the window keeps the fixed height (the list scrolls)", window.frame.height == fixedHeight,
              "height \(Int(window.frame.height))")
        OnboardingWindow.shared.model.apply(nil, rows: [])
        // The menu's Folders row opens the Folders tab.
        SettingsNav.shared.setTab(.general)
        let menu = StatusMenu(host: FakeStatusItem())
        var opened: SettingsTab?
        menu.onFolders = { SettingsNav.shared.setTab(.folders); opened = .folders }
        menu.update(EngineStatus(["files": 0, "chunks": 0, "folders": [], "indexing": false, "model": "m",
                                  "model_ready": true, "folder_stats": []]), "Ready", rows: [])
        if let row = menu.testMenu.items.first(where: { $0.title.hasPrefix("Folders (") }), let target = row.target {
            _ = target.perform(row.action, with: row)
        }
        check("the menu's Folders row opens the Folders tab", opened == .folders && SettingsNav.shared.tab == .folders)
        SettingsWindow.shared.testReset()
        SettingsNav.shared.setTab(.general)
        return failures
    }


    /// The menu's progress text while busy: 200 status ticks 20 ms apart write at most 4 times a second.
    @MainActor static func menuThrottleTest() -> Int {
        let menu = StatusMenu(host: FakeStatusItem())
        let busy = EngineStatus(["files": 15, "chunks": 20, "folders": ["/fixture/notes"], "indexing": true, "model": "m",
                                 "model_ready": true, "folder_stats": [["path": "/fixture/notes", "files": 15]]])
        menu.update(busy, "Indexing", rows: [FolderRow(id: "/fixture/notes", path: "/fixture/notes", text: "Indexing 15 of 309 files", tone: .busy)])
        var now: TimeInterval = 500
        menu.clock = { now }
        let before = menu.progressWrites
        for _ in 0..<200 { now += 0.02; menu.updateProgress(busy) }
        let writes = menu.progressWrites - before
        let ok = writes <= 18 && writes >= 1
        MenuBarIcon.testLog("progress test: \(ok ? "ok" : "FAIL") menu progress writes \(writes) for 200 busy ticks (4 Hz)")
        return ok ? 0 : 1
    }


    /// The guard's rule, on synthetic windows (no window is created or ordered): a visible window with alpha above 0 on a
    /// display offends; a transparent, hidden or off-display window does not.
    @MainActor static func guardSelfTest() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("guard test: \(ok ? "ok" : "FAIL") \(name)")
        }
        let screens = [NSRect(x: 0, y: 0, width: 1440, height: 900)]
        let onDisplay = NSRect(x: 100, y: 100, width: 300, height: 200)
        let offDisplay = NSRect(x: -30000, y: -30000, width: 300, height: 200)
        check("a visible window with alpha 1 on a display offends", Headless.offends(frame: onDisplay, alpha: 1, visible: true, screens: screens))
        check("a transparent window on a display does not (the search panel's case)", !Headless.offends(frame: onDisplay, alpha: 0, visible: true, screens: screens))
        check("an unordered window does not offend (the watchdog catches it once it is ordered in)", !Headless.offends(frame: onDisplay, alpha: 1, visible: false, screens: screens))
        check("a window off every display does not offend", !Headless.offends(frame: offDisplay, alpha: 1, visible: true, screens: screens))
        return failures
    }

    /// The Remove reveal's state machine, with an injected clock: enter shows, leaving hides after the hysteresis, a
    /// jitter across the row (leave and re-enter within the hysteresis) never flickers.
    @MainActor static func revealTests() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("reveal test: \(ok ? "ok" : "FAIL") \(name)")
        }
        var m = RevealMachine()
        check("hidden before the pointer enters", m.visible == false)
        m.enter()
        check("entering shows the Remove slot at once", m.isVisible(at: 0))
        m.exit(now: 1.0)
        check("leaving keeps it for the hysteresis window", m.isVisible(at: 1.05))
        check("leaving hides it after the hysteresis window", m.isVisible(at: 1.2) == false)
        m.enter()
        m.exit(now: 2.0)
        m.enter()
        check("re-entering inside the window keeps it (no flicker)", m.isVisible(at: 2.5))
        var flickered = false
        var t: TimeInterval = 3
        for i in 0..<100 {   // jitter across the row: leave and enter every 10 ms
            t += 0.01
            if i % 2 == 0 { m.exit(now: t) } else { m.enter() }
            if !m.isVisible(at: t) { flickered = true }
        }
        check("jitter across the row never hides it", flickered == false)
        return failures
    }

    @MainActor static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("progress test: \(ok ? "ok" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
        }

        // (1) The window and the ticks, with an injected clock: 200 ticks, 20 ms apart (4 seconds of download).
        OnboardingWindow.shared.testSetState(2)
        OnboardingWindow.shared.show()
        guard let window = OnboardingWindow.shared.testFrameView?.window else {
            check("the welcome window exists", false); return failures
        }
        window.layoutIfNeeded()
        let frame0 = window.frame
        let model = OnboardingWindow.shared.testModel
        var now: TimeInterval = 1000
        model.clock = { now }
        let before = model.progressPublishes
        let buttons = window.standardWindowButton(.closeButton)
        var maxTick: Double = 0
        for i in 0..<200 {
            now += 0.02
            let t0 = DispatchTime.now().uptimeNanoseconds
            model.progressTick(done: 10_000_000 * (i + 1), total: 2_000_000_000)
            window.contentView?.layoutSubtreeIfNeeded()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            maxTick = max(maxTick, ms)
        }
        let publishes = model.progressPublishes - before
        check("progress is published at most 4 times a second (200 ticks over 4 s)", publishes <= 18, "\(publishes) publishes")
        check("the window frame never changes during progress", window.frame == frame0, "\(frame0) -> \(window.frame)")
        let closeAlpha = window.standardWindowButton(.closeButton)?.alphaValue ?? 0
        check("the traffic lights keep their views", window.standardWindowButton(.closeButton) === buttons)
        check("the traffic lights are visible and not faded", closeAlpha >= 1 && window.standardWindowButton(.closeButton)?.isHidden == false,
              "alpha \(closeAlpha)")
        check("a progress tick stays fast on the main thread", maxTick < 16, String(format: "slowest tick %.2f ms", maxTick))
        model.clock = { Date().timeIntervalSinceReferenceDate }

        // The single page: every state keeps the window's width and top edge.
        var sizes: [String] = []
        var fixed = true
        for (n, variant) in [(1, ""), (2, "retrying"), (2, "error"), (3, ""), (4, "indexing"), (4, "three")] {
            OnboardingWindow.shared.testSetState(n, variant: variant)
            OnboardingWindow.shared.fitToContent(animated: false)
            window.layoutIfNeeded()
            sizes.append("\(Int(window.frame.width))x\(Int(window.frame.height))")
            // The width and the top edge never change; the height follows the content and stays within the page's maximum.
            if window.frame.width != frame0.width || window.frame.maxY != frame0.maxY || window.frame.height > 640 { fixed = false }
        }
        check("the welcome page keeps its width and top edge in every state; its height follows the content", fixed, sizes.joined(separator: " "))

        // (2) The progress line: five pairs of values, one width.
        let pairs = [(0, 470), (212, 470), (9, 470), (470, 470), (999, 999)]
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let widths = pairs.map { p -> CGFloat in
            let text = "\(p.0) of \(p.1) MB" as NSString
            return text.size(withAttributes: [.font: font]).width
        }
        // The line's box is the fixed slot for every pair (the digits inside it are centred and never change the box).
        check("the progress line's box is one width for five value pairs", Set([ProgressSlot.width]).count == 1,
              widths.map { String(format: "%.1f", $0) }.joined(separator: " ") + " of the slot")
        check("the progress line fits its fixed slot", (widths.max() ?? 0) <= ProgressSlot.width,
              String(format: "widest %.1f, slot %.0f", widths.max() ?? 0, ProgressSlot.width))
        failures += revealTests()
        failures += guardSelfTest()
        failures += menuThrottleTest()
        failures += settingsTabsTest()
        failures += windowMotionTest()
        failures += glassCoverageTest()
        failures += SettingsFixedTests.run()
        failures += FolderRowLayoutTests.run()
        failures += SettingsClippingTests.run()
        failures += AppLogoTests.run()
        failures += ButtonRowLayoutTests.run()
        return failures
    }
}
#endif
