#if DEBUG
import AppKit

/// Test only (needs SS_UNINSTALL_HOME and SS_HEADLESS=1): the folder scope, the search panel's place, and its folder list,
/// checked without showing anything on screen. Prints one line per check; `scope test: done` ends the run.
enum ScopeTests {
    private static var checks = 0
    private static var failures = 0

    private static func check(_ name: String, _ ok: Bool) {
        checks += 1
        if !ok { failures += 1 }
        MenuBarIcon.testLog("scope test: \(ok ? "ok" : "FAIL") \(name)")
    }

    private static func status(_ folders: [String], stats: [String: Int] = [:]) -> EngineStatus {
        EngineStatus([
            "files": stats.values.reduce(0, +), "chunks": 0, "indexing": false, "model": "m", "model_ready": true,
            "folders": folders,
            "folder_stats": folders.compactMap { path in stats[path].map { ["path": path, "files": $0] } },
        ])
    }

    static func run(_ search: SearchController) {
        // The menu-bar visibility reset, on a memory store: a hidden item is made visible; an absent or visible key is left alone.
        let visibility = MemoryPrefs()
        visibility.set(false, forKey: StatusVisibility.key)
        check("hidden status item: the visibility key is set to true", StatusVisibility.ensureVisible(visibility) && visibility.bool(forKey: StatusVisibility.key))
        check("the visibility reset changes nothing once visible", !StatusVisibility.ensureVisible(visibility))
        let absent = MemoryPrefs()
        check("no visibility key: nothing is written", !StatusVisibility.ensureVisible(absent) && absent.object(forKey: StatusVisibility.key) == nil)

        let suite = MemoryPrefs()
        let a = "/tmp/fake/alpha", b = "/tmp/fake/beta", c = "/tmp/fake/gamma", d = "/tmp/fake/delta"

        // 1. Scope: every folder included by default; the request leaves the key out.
        let scope = FolderScope(defaults: suite)
        scope.reconcile(status([a, b, c], stats: [a: 12, b: 3, c: 0]))
        check("all included by default", scope.allIncluded && !scope.narrowed)
        check("request omits folders when all are included", scope.requestFolders == nil)
        check("badge and label when all are included", scope.badge == "3/3" && scope.accessibilityLabel == "Searching all 3 folders")
        check("file count from folder_stats", scope.fileCount(a) == 12 && scope.fileCount(c) == 0)

        // 2. Toggling one folder off narrows the scope, sends the included folders, and stores the excluded one.
        scope.toggle(b)
        check("narrowed after leaving one out", scope.narrowed && !scope.isIncluded(b))
        check("request lists the included folders", scope.requestFolders == [a, c])
        check("badge and label when narrowed", scope.badge == "2/3" && scope.accessibilityLabel == "Searching 2 of 3 folders")
        check("excluded folders stored in the app's defaults", suite.stringArray(forKey: FolderScope.excludedKey) == [b])

        // 3. The choice survives a restart (a new scope reads the defaults).
        let reloaded = FolderScope(defaults: suite)
        reloaded.reconcile(status([a, b, c]))
        check("choice survives a restart", reloaded.excluded == [b] && reloaded.requestFolders == [a, c])

        // 4. A removed folder drops out of the stored list; a new folder is included by default.
        reloaded.reconcile(status([a, c, d]))
        check("removed folder dropped from the stored list", suite.stringArray(forKey: FolderScope.excludedKey) == [])
        check("new folder included by default", reloaded.isIncluded(d) && reloaded.requestFolders == nil)

        // 5. Nothing selected: the search has nothing to look in, and the list says so.
        reloaded.setAll(included: false)
        check("none selected: request is an empty list", reloaded.noneIncluded && reloaded.requestFolders == [])
        check("none selected: label", reloaded.accessibilityLabel == "No folders selected")
        reloaded.setAll(included: true)
        check("All brings every folder back", reloaded.allIncluded && reloaded.requestFolders == nil)

        // 6. The engine being down changes nothing.
        reloaded.toggle(a)
        reloaded.reconcile(nil)
        check("engine down keeps the choice", reloaded.excluded == [a])

        // 7. The query request carries `folders` only when it is set.
        check("request without folders has no key", EngineManager.queryRequest("q", limit: 8, folders: nil)["folders"] == nil)
        check("request with folders has the key", (EngineManager.queryRequest("q", limit: 8, folders: [a])["folders"] as? [String]) == [a])
        check("request with no folder left has an empty list", (EngineManager.queryRequest("q", limit: 8, folders: [])["folders"] as? [String]) == [])

        // 8. The default place: centered horizontally, top edge at 78% of the visible height.
        let visible = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let origin = SearchPlacement.defaultOrigin(size: NSSize(width: 640, height: 64), in: visible)
        check("default place is centered and in the upper part", origin.x == 180 && origin.y == 560)

        // 9. A remembered place is restored on its screen; a place that no longer fits falls back to the default.
        let defaults = search.testHasDefaults
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let size = NSSize(width: 640, height: 64)
        let fitting = NSPoint(x: screen.visibleFrame.minX + 120, y: screen.visibleFrame.minY + 200)
        SearchPlacement.save(origin: fitting, screen: screen, defaults: defaults)
        check("remembered place is restored", SearchPlacement.restoredOrigin(size: size, screen: screen, defaults: defaults) == fitting)
        SearchPlacement.save(origin: NSPoint(x: screen.frame.minX + 50_000, y: screen.frame.minY), screen: screen, defaults: defaults)
        check("off-screen place falls back to the default", SearchPlacement.restoredOrigin(size: size, screen: screen, defaults: defaults) == nil)
        SearchPlacement.clear(screen: screen, defaults: defaults)
        check("reset forgets the remembered place", SearchPlacement.restoredOrigin(size: size, screen: screen, defaults: defaults) == nil)

        // 10. The double-click zone: the lens and the right margin of the top row, not the field or the rest of the panel.
        search.show()
        let panel = search.testPanel
        let h = panel.contentView?.bounds.height ?? 0, w = panel.contentView?.bounds.width ?? 0
        check("double-click on the lens is a reset zone", search.inResetZone(NSPoint(x: 20, y: h - 10)))
        check("double-click in the field is not", !search.inResetZone(NSPoint(x: w / 2, y: h - 10)))
        check("double-click below the top row is not", !search.inResetZone(NSPoint(x: 20, y: h - 80)))

        // 10b. The double-click reset: the remembered place on this screen is forgotten and the panel goes back to the default.
        search.show()
        let remembered = NSPoint(x: panel.frame.minX + 40, y: panel.frame.minY - 30)
        SearchPlacement.save(origin: remembered, screen: SearchPlacement.screen(holding: panel.frame), defaults: defaults)
        search.resetPosition()
        let resetScreen = SearchPlacement.screen(holding: panel.frame)
        let wantOrigin = SearchPlacement.defaultOrigin(size: panel.frame.size, in: resetScreen.visibleFrame)
        check("reset puts the panel back at the default place (got \(panel.frame.origin), want \(wantOrigin), screen \(resetScreen.visibleFrame))",
              panel.frame.origin == wantOrigin)
        check("reset forgets the saved place on that screen",
              SearchPlacement.restoredOrigin(size: panel.frame.size, screen: resetScreen, defaults: defaults) == nil)

        // 11. A drag: the panel is not dismissed while the mouse is down on it, and moving it remembers the place.
        search.show()
        search.testPressBegin()
        search.testResignKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            check("a drag on the panel does not dismiss it", search.isPanelVisible)
            let before = panel.frame.origin
            panel.setFrame(NSRect(origin: NSPoint(x: before.x + 30, y: before.y - 20), size: panel.frame.size), display: true)
            search.testMoved()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let screenNow = SearchPlacement.screen(holding: panel.frame)
                check("moving the panel remembers its place for the screen",
                      SearchPlacement.restoredOrigin(size: panel.frame.size, screen: screenNow, defaults: defaults) == panel.frame.origin)
                search.testPressEnd()
                search.testResignKey()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    check("focus loss after the drag dismisses the panel", !search.isPanelVisible)
                    dragAnywhereOnTopRow(search)
                    continueWithPopover(search)
                }
            }
        }
    }

    /// 11b. Dragging anywhere on the header or the footer moves the panel, the field included. The scope chip and the rows below
    /// do not start a drag, and a plain click does not move it.
    private static func dragAnywhereOnTopRow(_ search: SearchController) {
        search.show()
        let panel = search.testPanel
        let origin = panel.frame.origin
        let w = panel.contentView?.bounds.width ?? 640, h = panel.contentView?.bounds.height ?? 64
        func screen(_ p: NSPoint) -> NSPoint { NSPoint(x: origin.x + p.x, y: origin.y + p.y) }

        let field = NSPoint(x: w / 2, y: h - 30)
        search.testPress(at: field, screen: screen(field))
        let movedFromField = search.testDrag(to: screen(NSPoint(x: field.x + 40, y: field.y - 25)))
        search.testRelease()
        check("dragging from the text field moves the panel", movedFromField && panel.frame.origin == NSPoint(x: origin.x + 40, y: origin.y - 25))

        search.show()
        let origin2 = panel.frame.origin
        let chip = NSPoint(x: w - 79, y: h - 31)   // the scope chip, at the top right
        search.testPress(at: chip, screen: screen(chip))
        let movedFromCircle = search.testDrag(to: screen(NSPoint(x: chip.x - 60, y: chip.y)))
        search.testRelease()
        check("dragging from the scope chip does not move the panel", !movedFromCircle && panel.frame.origin == origin2)

        search.testSetResults((0..<3).map { Hit(id: "\($0)", path: "/fixture/notes/file-\($0).txt", score: 0.5, similarity: nil, snippet: "a snippet") }, notice: "")
        search.show()
        let origin3 = panel.frame.origin
        let hNow = panel.contentView?.bounds.height ?? h
        let row = NSPoint(x: w / 2, y: hNow - 130)   // the first result row, under the header and the section label
        search.testPress(at: row, screen: screen(row))
        let movedFromRow = search.testDrag(to: screen(NSPoint(x: row.x + 50, y: row.y)))
        search.testRelease()
        check("dragging from a result row does not move the panel", !movedFromRow && panel.frame.origin == origin3)

        search.show()
        let origin5 = panel.frame.origin
        let hint = NSPoint(x: w * 0.3, y: 19)   // the footer (the key hints), an empty part of it, at the bottom
        search.testPress(at: hint, screen: screen(hint))
        let movedFromHint = search.testDrag(to: screen(NSPoint(x: hint.x + 30, y: hint.y - 20)))
        search.testRelease()
        check("dragging from the footer (the key hints) moves the panel", movedFromHint && panel.frame.origin == NSPoint(x: origin5.x + 30, y: origin5.y - 20))

        search.show()
        let origin4 = panel.frame.origin
        search.testPress(at: field, screen: screen(field))
        search.testRelease()
        check("a plain click on the field does not move the panel", panel.frame.origin == origin4)
    }

    /// Polls a condition on the main run loop every 10 ms, for at most `timeout` seconds, then runs `then` with the result.
    /// A bounded wait for a real state change: it never sleeps for a fixed time, and it reports a timeout as a failure.
    private static func eventually(_ what: String, timeout: TimeInterval = 3, _ condition: @escaping () -> Bool,
                                   then: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func poll() {
            if condition() { then(true); return }
            if Date() >= deadline { check("\(what) (timed out after \(timeout) s)", false); then(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
        }
        poll()
    }

    /// 12. The folder list: created once, hover jitter never opens or closes it, the grace holds, a click pins it.
    /// Deterministic: the jitter is synchronous (no main-queue turn in the loop, so no grace timer can fire inside it), and
    /// every wait is a bounded poll for the state it needs, not a fixed delay.
    private static func continueWithPopover(_ search: SearchController) {
        search.show()
        eventually("the panel is shown and key before the jitter", { search.isPanelVisible && search.testPanel.isKeyWindow }) { settled in
            guard settled else { return }
            let madeBefore = FolderPopoverController.instancesMade
            let opensBefore = search.popoverOpenCount, closesBefore = search.popoverCloseCount
            for _ in 0..<50 {                   // jitter: the pointer crosses the edge and comes back, all inside the grace
                search.testHoverEnter()
                search.testHoverExit()
                search.testHoverEnter()
            }
            check("hover jitter opens the list once", search.popoverOpenCount - opensBefore == 1)
            check("hover jitter closes it never", search.popoverCloseCount - closesBefore == 0)
            check("the list is created once, not per hover", FolderPopoverController.instancesMade - madeBefore <= 1)
            search.testHoverExit()
            eventually("leaving closes the list after the grace", { search.popoverCloseCount - closesBefore == 1 }) { _ in
                search.testFolderClick()
                search.testHoverExit()
                eventually("a click pins the list open", { search.popoverCloseCount - closesBefore == 1 }) { _ in
                    search.testFolderClick()
                    check("a second click closes it", search.popoverCloseCount - closesBefore == 2)
                    check("the list was made once in this run", FolderPopoverController.instancesMade - madeBefore <= 1)
                    MenuBarIcon.testLog("scope test: done, \(checks) checks, \(failures) failures")
                    AppQuit.now()
                }
            }
        }
    }
}
#endif
