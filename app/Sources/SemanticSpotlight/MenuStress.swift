#if DEBUG
import AppKit

/// Test only (needs SS_UNINSTALL_HOME, like the other hooks) and headless only (needs SS_HEADLESS=1): both drive the
/// status menu with simulated engine states. Nothing is shown on screen: the menu is never popped up, the status item
/// is a fake host, and the open and close events are sent to the menu's delegates directly (the top-level menu and
/// the Folders submenu, as a click would).
///  - `run` (--stress-menu-for-test N): random states, many steps, some through a background queue hop. Every sixth
///    step opens the menu and the Folders submenu, changes the state while they are open, and closes them.
///  - `counter` (--headless-counter-for-test N): progress ticks while the menu is open, then one structural change;
///    counts status-item creations, menu attachments, rebuilds, items made, and busy-animation frames.
enum MenuStress {
    /// A small deterministic generator, so a failing seed can be replayed.
    struct Rng: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
    }

    static func refuseUnlessHeadless() -> Bool {
        guard Headless.enabled else {
            MenuBarIcon.testLog("menu test refused: it needs SS_HEADLESS=1, so nothing is put on the desktop")
            AppQuit.now()
            return false
        }
        return true
    }

    /// Opens the top-level menu and its Folders submenu, the way a click on the Folders row does.
    static func open(_ menu: StatusMenu) -> [NSMenu] {
        let top = menu.testMenu
        top.delegate?.menuWillOpen?(top)
        return [top]
    }

    /// Closes what `open` opened: submenu first, then the top-level menu, as AppKit does.
    static func close(_ opened: [NSMenu]) {
        for m in opened.reversed() { m.delegate?.menuDidClose?(m) }
    }

    static func run(_ menu: StatusMenu, steps: Int) {
        guard refuseUnlessHeadless() else { return }
        let seed = UInt64(Uninstall.env("SS_TEST_SEED") ?? "") ?? 1
        var rng = Rng(state: seed | 1)
        var step = 0
        var trackingSteps = 0
        var rebuiltWhileOpen = 0
        func next() {
            guard step < steps else {
                MenuBarIcon.testLog("menu stress: tracking steps \(trackingSteps), rebuilt while open in \(rebuiltWhileOpen)")
                MenuBarIcon.testLog("menu stress: items made \(menu.itemsMade), reused \(menu.reusedItems), misattached \(menu.misattachedItems)")
                MenuBarIcon.testLog("menu stress: done, \(steps) steps, \(menu.rebuildCount) rebuilds, seed \(seed)")
                AppQuit.now()
                return
            }
            step += 1
            let status = randomStatus(&rng)
            let message = ["Starting engine…", "Ready", "Engine stopped", "Indexing…"].randomElement(using: &rng) ?? ""
            let rows = randomRows(&rng)
            let apply = { menu.update(status, message, rows: rows); menu.updateProgress(status) }
            if step % 6 == 0 {
                // The menu and its submenu are open while the state changes: nothing may rebuild until they close.
                let before = menu.rebuildCount
                let opened = open(menu)
                apply()
                let whileOpen = menu.rebuildCount - before
                close(opened)
                trackingSteps += 1
                if whileOpen != 0 { rebuiltWhileOpen += 1 }
                DispatchQueue.main.async { next() }
            } else if step % 5 == 0 {
                DispatchQueue.global(qos: .userInitiated).async {
                    DispatchQueue.main.async { apply(); next() }
                }
            } else {
                apply()
                DispatchQueue.main.async { next() }
            }
        }
        DispatchQueue.main.async { next() }
    }

    /// Progress ticks through the real update path while the menu and its submenu are open, then one structural change.
    static func counter(_ menu: StatusMenu, ticks: Int) {
        guard refuseUnlessHeadless() else { return }
        let fake = menu.hostForTest as? FakeStatusItem
        let realBefore = StatusMenu.realItemsCreated
        let attachmentsBefore = fake?.menuAssignments ?? -1
        let folder = FolderRow(id: "/tmp/fake/a", path: "/tmp/fake/a", text: "Indexing…", tone: .busy)
        let total = 300
        func status(_ i: Int) -> EngineStatus {
            // Every tick moves the progress count and, every third tick, the file count. Nothing structural changes.
            EngineStatus(["files": 30 + i / 3, "chunks": 280 + i, "folders": ["/tmp/fake/a"], "indexing": true, "model": "m",
                          "model_ready": true, "progress": ["phase": "indexing", "done": i % total, "total": total]])
        }
        // The summary's wording, for sample folder states. A failure or an empty folder is always named.
        let row = { (tone: FolderRow.Tone) in FolderRow(id: "x", path: "/x", text: "", tone: tone) }
        let samples: [[FolderRow]] = [[row(.ok), row(.ok)], [row(.ok), row(.error)], [row(.ok), row(.warning)],
                                      [row(.ok), row(.busy), row(.busy)], [row(.error), row(.busy)], []]
        for sample in samples { MenuBarIcon.testLog("summary: \(StatusMenu.folderSummary(sample))") }
        // Start from a known structure: one folder row, the engine running, then open the menu and the Folders submenu.
        menu.update(status(0), "Indexing…", rows: [folder])
        let opened = open(menu)
        let rebuildsBeforeTicks = menu.rebuildCount
        let itemsBeforeTicks = menu.itemsMade
        var i = 0
        func tick() {
            guard i < ticks else {
                let rebuildsDuringTicks = menu.rebuildCount - rebuildsBeforeTicks
                let itemsDuringTicks = menu.itemsMade - itemsBeforeTicks
                // One structural change (the folder's phase) while the menu is still open: it must wait for the close.
                let changed = FolderRow(id: folder.id, path: folder.path, text: "Ready", tone: .ok)
                let rebuildsBeforeChange = menu.rebuildCount
                menu.update(status(i), "Indexing…", rows: [changed])
                let rebuildsWhileOpen = menu.rebuildCount - rebuildsBeforeChange
                close(opened)
                let rebuildsAfterClose = menu.rebuildCount - rebuildsBeforeChange
                let attachments = (fake?.menuAssignments ?? -1) - attachmentsBefore
                let created = StatusMenu.realItemsCreated - realBefore
                MenuBarIcon.testLog("counter: \(ticks) progress ticks while open, status items created \(created), menu attachments \(attachments), rebuilds during ticks \(rebuildsDuringTicks), items made during ticks \(itemsDuringTicks)")
                MenuBarIcon.testLog("counter: one structural change while open: rebuilds while open \(rebuildsWhileOpen), rebuilds after close \(rebuildsAfterClose)")
                MenuBarIcon.testLog("counter: items made \(menu.itemsMade), reused \(menu.reusedItems), misattached \(menu.misattachedItems)")
                AppQuit.now()
                return
            }
            let s = status(i)
            menu.update(s, "Indexing…", rows: [folder])
            menu.updateProgress(s)
            i += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.005) { tick() }   // 200 ticks take about 1 s: the busy timer runs
        }
        DispatchQueue.main.async { tick() }
    }

    static func randomStatus(_ rng: inout Rng) -> EngineStatus? {
        if Int.random(in: 0..<8, using: &rng) == 0 { return nil }   // engine not running
        var r: [String: Any] = [
            "files": Int.random(in: 0...500, using: &rng), "chunks": Int.random(in: 0...3000, using: &rng),
            "folders": (0..<Int.random(in: 0...4, using: &rng)).map { "/tmp/fake/folder\($0)" },
            "model": "fake-model", "model_ready": Bool.random(using: &rng),
        ]
        switch Int.random(in: 0..<4, using: &rng) {
        case 0:   // an older engine: the indexing flag only, no progress key
            r["indexing"] = Bool.random(using: &rng)
        default:  // a newer engine: phase, done and total; done may pass total, as a race can make it
            let phase = ["idle", "scanning", "indexing"].randomElement(using: &rng) ?? "idle"
            r["progress"] = ["phase": phase, "done": Int.random(in: 0...400, using: &rng), "total": Int.random(in: 0...300, using: &rng)]
            r["indexing"] = phase != "idle"
        }
        return EngineStatus(r)
    }

    static func randomRows(_ rng: inout Rng) -> [FolderRow] {
        let tones: [FolderRow.Tone] = [.ok, .busy, .warning, .error]
        return (0..<Int.random(in: 0...4, using: &rng)).map { i in
            let path = "/tmp/fake/folder\(i)"
            return FolderRow(id: path, path: path, text: "Row \(i)", tone: tones.randomElement(using: &rng) ?? .ok)
        }
    }
}
#endif
