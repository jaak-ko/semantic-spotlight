import AppKit

/// Menu bar icon and menu. Top to bottom: the engine line and status (counts, model, progress while busy), one
/// "Folders" row with a summary that opens a submenu of folders, a separator, then Reindex, Show Search, Settings and Quit.
///
/// Main thread only. The rules that keep the menu stable:
///  - One status item, created once (`realItemsCreated` counts it). The menu is attached to it once, in init.
///  - Every rebuild creates new NSMenuItems and new submenus. An item that still belongs to a menu cannot be inserted
///    into another one: AppKit throws "Item to be inserted into menu already is in another menu" from insertItem:atIndex:.
///  - A rebuild happens only when the menu's structure changes: the message, whether the engine runs, the model, and
///    the folder rows (path, state, text). Progress ticks never change the structure. Counts, the progress row and the
///    folders summary are structural (the summary is built from the rows), so only the structural signature changes them.
///  - A structural rebuild never happens while the menu or any of its submenus is open. It waits for the top-level
///    menuDidClose.
///  - Every entry point checks that it runs on the main queue.
final class StatusMenu: NSObject, NSMenuDelegate {
    var onShow: (() -> Void)?
    var onReindex: (() -> Void)?
    var onRemove: ((String) -> Void)?
    var onSettings: (() -> Void)?
    /// Opens Settings at its Folders section (the menu's Folders row).
    var onFolders: (() -> Void)?
    var onRetry: ((String) -> Void)?

    /// The widest text line in the menu, in points. Longer titles (folder paths, engine messages) are cut in the middle
    /// so the menu never grows past this; the menu's minimum width keeps short menus from looking cramped.
    static let maxTitleWidth: CGFloat = 240
    static let minMenuWidth: CGFloat = 220
    /// What the menu adds around a text row (the margins, the key column, the submenu arrow) and around a custom view
    /// row (its margins). Measured with NSMenu.size in the theme test: a text row of width t makes a menu of t + 100, a
    /// view row of width v makes a menu of v + 39.
    static let textRowOverhead: CGFloat = 100
    static let viewRowOverhead: CGFloat = 39

    /// `text` cut in the middle with "…" when it is wider than `width` in the menu font. Keeps the start and the end.
    static func fitted(_ text: String, width: CGFloat = maxTitleWidth) -> String {
        let font = NSFont.menuFont(ofSize: 0)
        func measure(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        guard measure(text) > width else { return text }
        let chars = Array(text)
        var head = chars.count / 2, tail = chars.count - head
        func build() -> String { String(chars[0..<head]) + "…" + String(chars[(chars.count - tail)...]) }
        while measure(build()) > width, head + tail > 2 {
            if head >= tail { head -= 1 } else { tail -= 1 }
        }
        return build()
    }

    /// Status items this process has created for real. The app creates one; the counter test reads it.
    private(set) static var realItemsCreated = 0

    private let item: MenuBarHost
    private let menu = NSMenu()
    private var status: EngineStatus?
    private var message = "Starting engine…"
    private var rows: [FolderRow] = []
    private var lastStructure = ""
    private var openMenus = Set<ObjectIdentifier>()   // the top-level menu and any submenu being tracked
    private var rebuildPending = false                // a structural change arrived while a menu was open

    /// The items a rebuild made. updateProgress and the counts change them in place; a rebuild makes new ones.
    private var progressItem: NSMenuItem?
    private var progressLabel: NSTextField?
    private var progressBar: NSProgressIndicator?
    private var statsItem: NSMenuItem?

    /// How many times the menu has been rebuilt (the stress and counter tests read it).
    private(set) var rebuildCount = 0
    /// Headless runs keep every item they make and check that none is ever reused or attached to the wrong menu.
    private(set) var itemsMade = 0
    private(set) var reusedItems = 0
    private(set) var misattachedItems = 0
    private var auditedItems: [NSMenuItem] = []
    private var auditedIDs = Set<ObjectIdentifier>()

#if DEBUG
    /// The menu itself, for the stress test to open and close the way a click does.
    var testMenu: NSMenu { menu }
    /// The folders submenu as the last rebuild made it, for the stress test.
    /// The status item host (the fake one in headless runs), for the counter test.
    var hostForTest: MenuBarHost { item }
#endif

    /// `host` is the status item. Nil creates the real one; headless runs and tests pass a fake host.
    init(host: MenuBarHost? = nil) {
        if let host {
            item = host
        } else {
            // macOS can hide a status item through a stored preference: make it visible before and after creating it.
            StatusVisibility.ensureVisible(AppPrefs.store)
            let real = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            real.isVisible = true
            item = real
            StatusMenu.realItemsCreated += 1
        }
        super.init()
        MenuBarIcon.install(on: item.button)   // the one and only icon assignment
        menu.delegate = self
        menu.minimumWidth = StatusMenu.minMenuWidth
        item.menu = menu
        update(nil, message, rows: [])
    }

    func update(_ status: EngineStatus?, _ message: String, rows: [FolderRow]) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.status = status
        self.message = message
        self.rows = rows
        updateStats()
        let structure = [message, status == nil ? "no engine" : "engine",
                         status?.model ?? "", "\(status?.modelReady ?? false)",
                         rows.map { "\($0.path)|\($0.tone)|\($0.text)" }.joined(separator: "\n")].joined(separator: "|")
        guard structure != lastStructure else { return }
        lastStructure = structure
        if !openMenus.isEmpty {
            rebuildPending = true   // rebuilding now would dismiss the menu the user is looking at
        } else {
            rebuild()
        }
    }

    /// Shows the progress row only while the engine is busy. Changes the row in place, so it is safe while the menu
    /// is open.
    /// The menu's progress text is written at most 4 times a second while busy (a hidden or idle state is always applied).
    var clock: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    private var lastProgressWrite: TimeInterval = -.infinity
    private(set) var progressWrites = 0

    func updateProgress(_ status: EngineStatus?) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let row = progressItem else { return }
        if let s = status, s.busy {
            let now = clock()
            guard now - lastProgressWrite >= 0.25 else { return }
            lastProgressWrite = now
            progressWrites += 1
        }
        guard let s = status, s.busy else {
            row.isHidden = true
            progressBar?.stopAnimation(nil)
            #if DEBUG
            MenuBarIcon.testLog("progress hidden")
            #endif
            return
        }
        row.isHidden = false
        fillProgress(s)
    }

    /// The counts line, changed in place.
    private func updateStats() {
        guard let s = status, let line = statsItem else { return }
        line.title = "\(s.files) files · \(s.chunks) chunks · \(s.busy ? "busy" : "idle")"
    }

    private func fillProgress(_ s: EngineStatus) {
        progressLabel?.stringValue = s.progressLine
        guard let bar = progressBar else { return }
        if s.determinate {
            bar.stopAnimation(nil)
            bar.isIndeterminate = false
            bar.maxValue = Double(s.total)
            bar.doubleValue = Double(min(s.done, s.total))
            #if DEBUG
            MenuBarIcon.testLog("progress determinate \(min(s.done, s.total))/\(s.total) \"\(s.progressLine)\"")
            #endif
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
            #if DEBUG
            MenuBarIcon.testLog("progress indeterminate \"\(s.progressLine)\"")
            #endif
        }
    }

    /// The progress row fills the menu's width: the widest text row decides the menu's width (text rows add
    /// `textRowOverhead`), and the custom view takes that width less its own overhead. Only rebuild calls it.
    private func fitProgressRow(_ row: NSMenuItem) {
        let font = NSFont.menuFont(ofSize: 0)
        let widest = menu.items.filter { $0.view == nil && !$0.isSeparatorItem && !$0.title.isEmpty }
            .map { ($0.title as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        let menuWidth = max(StatusMenu.minMenuWidth, widest + StatusMenu.textRowOverhead)
        let width = menuWidth - StatusMenu.viewRowOverhead
        row.view?.frame.size.width = width
        progressLabel?.frame.size.width = width - 28
        progressBar?.frame.size.width = width - 28
    }

    /// A new progress row with new views. Only rebuild calls it.
    private func makeProgressRow() -> NSMenuItem {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: StatusMenu.minMenuWidth, height: 40))   // hidden when idle, so it must not widen the menu
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 14, y: 20, width: StatusMenu.minMenuWidth - 28, height: 16)
        label.font = .systemFont(ofSize: 11)
        label.textColor = Theme.inkNS
        let bar = NSProgressIndicator()
        bar.frame = NSRect(x: 14, y: 8, width: StatusMenu.minMenuWidth - 28, height: 12)
        bar.style = .bar
        bar.controlSize = .small
        bar.minValue = 0
        bar.maxValue = 1
        box.addSubview(label)
        box.addSubview(bar)
        let row = NSMenuItem()
        row.view = box
        progressLabel = label
        progressBar = bar
        return row
    }

    /// The one-line summary of the folders. A problem is always named in it, in plain words.
    static func folderSummary(_ rows: [FolderRow]) -> String {
        guard !rows.isEmpty else { return "none yet" }
        var parts: [String] = []
        let failed = rows.filter { $0.tone == .error }.count
        let empty = rows.filter { $0.tone == .warning }.count
        let busy = rows.filter { $0.tone == .busy }.count
        if failed > 0 { parts.append("\(failed) failed to add") }
        if empty > 0 { parts.append("\(empty) with no supported files") }
        if busy > 0 { parts.append("Indexing \(rows.count - busy) of \(rows.count)") }
        if parts.isEmpty { parts.append("All ready") }
        return parts.joined(separator: " · ")
    }

    /// The Folders row: one item, "Folders (N)…", which opens Settings at its Folders section. The row carries the state
    /// (indexing, a problem) in its title; there is no submenu.
    private func makeFoldersRow() -> NSMenuItem {
        let summary = StatusMenu.folderSummary(rows)
        let title = "Folders (\(rows.count))…" + (summary == "All ready" ? "" : " · \(summary)")
        return action(StatusMenu.fitted(title), #selector(openFolders))
    }

    private func rebuild() {
        dispatchPrecondition(condition: .onQueue(.main))
        rebuildCount += 1
        rebuildPending = false
        #if DEBUG
        MenuBarIcon.testLog("menu rebuild \(rebuildCount): \(lastStructure.prefix(120))")
        #endif
        menu.removeAllItems()
        menu.addItem(disabled("Engine: \(message)"))
        statsItem = nil
        if let s = status {
            let stats = disabled("")
            statsItem = stats
            menu.addItem(stats)
            // The short name only: the full repository path is in Settings' engine line, not in the menu.
            let model = s.model.split(separator: "/").last.map(String.init) ?? s.model
            menu.addItem(disabled(s.modelReady ? "Model: \(model)" : "Model: not downloaded"))
        }
        updateStats()
        let progress = makeProgressRow()
        progressItem = progress
        progress.isHidden = !(status?.busy ?? false)
        if let s = status, s.busy { fillProgress(s) }
        menu.addItem(progress)
        menu.addItem(makeFoldersRow())
        menu.addItem(.separator())
        menu.addItem(action("Reindex Now", #selector(reindex)))
        menu.addItem(action("Show Search", #selector(showSearch)))
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(action("Quit Semantic Spotlight", #selector(quit), key: "q"))
        fitProgressRow(progress)
        if Headless.enabled { audit(menu) }
    }

    /// Headless only: every item must be new, and must belong to the menu it is in.
    private func audit(_ m: NSMenu) {
        for entry in m.items {
            itemsMade += 1
            let id = ObjectIdentifier(entry)
            if auditedIDs.contains(id) { reusedItems += 1 }
            auditedIDs.insert(id)
            auditedItems.append(entry)   // kept alive, so no identity is reused by a later item
            if entry.menu !== m { misattachedItems += 1 }
            if let sub = entry.submenu { audit(sub) }
        }
    }

    // MARK: - Open and close

    func menuWillOpen(_ menu: NSMenu) {
        openMenus.insert(ObjectIdentifier(menu))
    }

    /// Closing the top-level menu ends the whole tracking session, so it also releases any submenu still counted.
    func menuDidClose(_ menu: NSMenu) {
        if menu === self.menu { openMenus.removeAll() } else { openMenus.remove(ObjectIdentifier(menu)) }
        if openMenus.isEmpty && rebuildPending { rebuild() }   // the change that arrived while open, now that it is safe
    }

    /// The status mark of a folder row. The ok check is green: a coloured image (not a template), so the menu keeps it.
    private func markImage(_ tone: FolderRow.Tone) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol(for: tone), accessibilityDescription: nil)
        guard tone == .ok, let colored = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [Theme.successNS]))
        else { return image }
        colored.isTemplate = false
        return colored
    }

    private func symbol(for tone: FolderRow.Tone) -> String {
        switch tone {
        case .ok: return "checkmark.circle.fill"
        case .busy: return "arrow.triangle.2.circlepath"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: StatusMenu.fitted(title), action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func showSearch() { onShow?() }
    @objc private func openFolders() { onFolders?() }
    @objc private func reindex() { onReindex?() }
    @objc private func openSettings() { onSettings?() }
    @objc private func retryFolder(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { onRetry?(path) }
    }
    @objc private func removeFolder(_ sender: NSMenuItem) {
        if let path = sender.representedObject as? String { onRemove?(path) }
    }
    /// The menu's Quit item, and the test that presses it. Same exit as the Quit button.
    @objc func quit() { AppQuit.now() }
}
