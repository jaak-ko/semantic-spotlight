#if DEBUG
import AppKit

/// Test only: `--dump-ui` with the test roots (SS_UNINSTALL_HOME). It builds the production menu and the production search
/// panel, feeds them the states a user can be in, and prints what they contain: menu items with their hidden flags and
/// submenus, and the panel's view tree with frames, hidden flags and alpha. Nothing is shown: the status item is made
/// hidden (`isVisible = false`), the panel and its list are laid out but never ordered in, and the engine (when started)
/// runs under the test's HOME. Engine startup is part of the dump: it reports whether the bundled daemon came up.
enum UIDump {
    static func run(engine: EngineManager) {
        print("== engine (HOME=\(SemPaths.home))")
        var first: EngineStatus?
        var message = ""
        let deadline = Date().addingTimeInterval(40)
        engine.onChange = { status, text in
            message = text
            if first == nil, status != nil { first = status }
        }
        engine.start()
        while first == nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if let s = first {
            print("   engine: running, folders \(s.folders.count), model_ready \(s.modelReady), message \"\(message)\"")
        } else {
            print("   engine: NOT running after 40 s, message \"\(message)\"")
        }
        let log = (try? String(contentsOfFile: SemPaths.log, encoding: .utf8)) ?? "(no daemon log)"
        print("   daemon log (last 3 lines):")
        for line in log.split(separator: "\n").suffix(3) { print("     \(line)") }
        engine.onChange = nil

        // The production objects. The status item is the fake host: a real status item's visibility is written by macOS
        // into the app's preferences (NSStatusItem VisibleCC), so the dump would change the user's menu-bar setting.
        // The menu code is the same either way; only the host differs.
        let scope = FolderScope(defaults: MemoryPrefs())
        let search = SearchController(engine: engine, scope: scope, defaults: MemoryPrefs())
        let menu = StatusMenu(host: FakeStatusItem())

        let states: [(String, EngineStatus?, String, [FolderRow])] = [
            ("(a) fresh install: 0 folders, model missing",
             status(folders: [], model: false), "Running", []),
            ("(b) model ready, 0 folders",
             status(folders: [], model: true), "Running", []),
            ("(c) one folder, idle",
             status(folders: ["/fixture/notes"], model: true),
             "Running", [FolderRow(id: "n", path: "/fixture/notes", text: "Ready", tone: .ok)]),
            ("(d) three folders, indexing with progress",
             status(folders: ["/a/one", "/a/two", "/a/three"], model: true, progress: ("indexing", 30, 90)),
             "Running",
             [FolderRow(id: "1", path: "/a/one", text: "Indexing…", tone: .busy),
              FolderRow(id: "2", path: "/a/two", text: "Indexing…", tone: .busy),
              FolderRow(id: "3", path: "/a/three", text: "Ready", tone: .ok)]),
            ("(e) one folder with a problem",
             status(folders: ["/Volumes/Missing/folder"], model: true),
             "Running", [FolderRow(id: "p", path: "/Volumes/Missing/folder", text: "Could not add folder: no such folder", tone: .error)]),
        ]
        for (title, s, text, rows) in states {
            scope.reconcile(s)
            menu.update(s, text, rows: rows)
            menu.updateProgress(s)
            print("\n== \(title)")
            print("-- menu (\(menu.testMenu.items.count) top-level items)")
            for line in menuLines(menu.testMenu, depth: 0) { print(line) }
            print("-- search panel (view tree, laid out, never shown)")
            for line in search.debugViewTree() { print(line) }
            let dir = ProcessInfo.processInfo.environment["SS_DUMP_DIR"] ?? SemPaths.home
            let tag = String(title.prefix(3)).filter { $0.isLetter }
            let rendered = search.debugSnapshot(panelTo: "\(dir)/ui-\(tag)-panel.png", popoverTo: "\(dir)/ui-\(tag)-list.png")
            print("-- rendered offscreen: \(rendered ? "ui-\(tag)-panel.png, ui-\(tag)-list.png" : "failed")")
        }
        print("\n== popover (created, never shown)")
        for line in search.debugPopoverTree() { print(line) }

        engine.shutdown()
        print("\n== done")
    }

    private static func status(folders: [String], model: Bool, progress: (String, Int, Int)? = nil) -> EngineStatus {
        var r: [String: Any] = [
            "files": 0, "chunks": 0, "folders": folders, "indexing": progress != nil,
            "folder_stats": folders.map { ["path": $0, "files": 0] },
            "model": "intfloat/multilingual-e5-small", "model_ready": model,
            "progress": ["phase": progress?.0 ?? "idle", "done": progress?.1 ?? 0, "total": progress?.2 ?? 0],
        ]
        if progress != nil { r["indexing"] = true }
        return EngineStatus(r)
    }

    private static func menuLines(_ menu: NSMenu, depth: Int) -> [String] {
        var lines: [String] = []
        let pad = String(repeating: "  ", count: depth + 1)
        for item in menu.items {
            var line = "\(pad)\(item.isSeparatorItem ? "----" : "\"\(item.title)\"")"
            if item.isHidden { line += "  [HIDDEN]" }
            if item.submenu != nil { line += "  [submenu: \(item.submenu?.items.count ?? 0) items]" }
            if let view = item.view {
                line += "  [view \(type(of: view)) frame \(Int(view.frame.width))x\(Int(view.frame.height))]"
                for sub in view.subviews {
                    if let label = sub as? NSTextField { line += " label=\"\(label.stringValue)\"" }
                    if let bar = sub as? NSProgressIndicator { line += " bar(hidden \(bar.isHidden), value \(bar.doubleValue)/\(bar.maxValue))" }
                }
            }
            lines.append(line)
            if let sub = item.submenu { lines += menuLines(sub, depth: depth + 1) }
        }
        return lines
    }
}

/// Formats a view tree for the dump: class, frame, hidden flag and alpha, one line per view.
enum UIDumpFormat {
    /// Renders a view offscreen (cacheDisplay: nothing is put on the screen) to a PNG file.
    static func png(_ view: NSView?, to path: String) -> Bool {
        guard let view, view.bounds.width > 0, view.bounds.height > 0,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return FileManager.default.createFile(atPath: path, contents: data)
    }

    static func tree(_ view: NSView?, maxLines: Int = 160) -> [String] {
        var lines: [String] = []
        func walk(_ v: NSView, depth: Int) {
            guard lines.count < maxLines, depth <= 9 else { return }
            let f = v.frame
            let label = v.accessibilityLabel().map { " label=\"\($0)\"" } ?? ""
            lines.append("\(String(repeating: "  ", count: depth))\(type(of: v)) frame(\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height)))\(v.isHidden ? " HIDDEN" : "") alpha \(v.alphaValue)\(label)")
            for sub in v.subviews { walk(sub, depth: depth + 1) }
        }
        if let view { walk(view, depth: 0) }
        if lines.count >= maxLines { lines.append("  ... (truncated)") }
        if let view {
            // SwiftUI draws its text and labels outside the AppKit view tree; the accessibility tree lists them.
            lines.append("  -- accessibility (SwiftUI text, labels, buttons)")
            var seen = 0
            // The accessibility selectors are called by name: SwiftUI's elements do not conform to the Swift protocols.
            func call(_ obj: AnyObject, _ name: String) -> AnyObject? {
                let sel = NSSelectorFromString(name)
                guard obj.responds(to: sel) else { return nil }
                return obj.perform(sel)?.takeUnretainedValue()
            }
            func ax(_ element: AnyObject, depth: Int) {
                guard seen < 60, depth <= 9 else { return }
                let role = (call(element, "accessibilityRole") as? String) ?? "?"
                let label = (call(element, "accessibilityLabel") as? String) ?? ""
                let value = (call(element, "accessibilityValue") as? String) ?? ""
                if !label.isEmpty || !value.isEmpty || role.contains("Button") || role.contains("StaticText") {
                    seen += 1
                    lines.append("  \(String(repeating: "  ", count: depth))\(role) \"\(label)\"\(value.isEmpty ? "" : " value=\"\(value)\"")")
                }
                for child in (call(element, "accessibilityChildren") as? [AnyObject]) ?? [] { ax(child, depth: depth + 1) }
            }
            ax(view, depth: 0)
        }
        return lines
    }
}
#endif
