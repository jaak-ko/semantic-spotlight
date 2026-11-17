import AppKit
import Combine
import QuickLookUI
import SwiftUI

/// The floating search window. Borderless and non-activating, so it does not take the frontmost app's menu bar.
/// It moves when the header or the footer is dragged (anywhere on them except the scope chip); see SearchController.mouse.
final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class SearchModel: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { search() } }
    }
    @Published private(set) var hits: [Hit] = []
    @Published var selection = 0
    @Published var listFocused = false     // Tab moves focus to the list; Space then previews
    @Published var folderFocused = false   // Tab reaches the scope chip; Return or Space works its list
    @Published var folderCursor = 0        // in the folder list: 0 All, 1 None, then one per registered folder
    @Published var folderPopoverOpen = false
    @Published var notice = ""
    @Published var focusTick = 0
    /// The most the result list may be tall (the controller sets it from the screen). Longer lists scroll.
    @Published var maxListHeight: CGFloat = SearchLayout.maxListHeight(screenVisibleHeight: 900)

    let scope: FolderScope
    /// Set by the controller: the scope chip's hover, and its click.
    var onFolderHover: ((Bool) -> Void)?
    var onFolderClick: (() -> Void)?

    private var task: Task<Void, Never>?
    private let engine: EngineManager
    private var cancellables = Set<AnyCancellable>()

    init(engine: EngineManager, scope: FolderScope) {
        self.engine = engine
        self.scope = scope
        // Including or leaving out a folder runs the current query again (the search debounces it).
        scope.$excluded.dropFirst().sink { [weak self] _ in self?.search() }.store(in: &cancellables)
    }

    var selected: Hit? { hits.indices.contains(selection) ? hits[selection] : nil }

#if DEBUG
    /// Test only: sets the results as the engine would (the notice follows the rule in `search`).
    func testSetResults(_ found: [Hit], notice newNotice: String) {
        hits = found
        notice = newNotice
        selection = 0
    }
#endif

    func reset() {
        listFocused = false
        folderFocused = false
        query = ""
        focusTick += 1
    }

    /// The pointer moved over a result row: that row becomes the selection, like the keyboard's selection. Only movement
    /// calls this (see SearchView); a row that appears or scrolls under a still pointer does not.
    func pointerMoved(toRow index: Int) {
        guard hits.indices.contains(index), index != selection else { return }
        selection = index
    }

    /// Click on a result row: select it and open it (set by the controller).
    var onOpenRow: ((Hit) -> Void)?

    func move(_ delta: Int) {
        guard !hits.isEmpty else { return }
        selection = min(max(selection + delta, 0), hits.count - 1)
    }

    /// Tab: field, then the scope chip, then the results (when there are any), then the field again.
    func cycleFocus() {
        if folderFocused {
            folderFocused = false
            if !hits.isEmpty { listFocused = true }
        } else if listFocused {
            listFocused = false
        } else {
            folderFocused = true
            folderCursor = 0
        }
    }

    var folderItemCount: Int { 2 + scope.registered.count }

    func moveFolderCursor(_ delta: Int) {
        folderCursor = min(max(folderCursor + delta, 0), folderItemCount - 1)
    }

    /// Return or Space in the folder list: All, None, or toggle the folder under the cursor.
    func activateFolderCursor() {
        switch folderCursor {
        case 0: scope.setAll(included: true)
        case 1: scope.setAll(included: false)
        default:
            let index = folderCursor - 2
            if scope.registered.indices.contains(index) { scope.toggle(scope.registered[index]) }
        }
    }

    /// Debounced (150 ms); stale responses are dropped by cancelling the task. Nothing is searched when no folder is
    /// included: the list says so instead.
    private func search() {
        task?.cancel()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            hits = []
            notice = ""
            selection = 0
            return
        }
        guard !scope.noneIncluded else {
            hits = []
            notice = "No folders selected"
            selection = 0
            return
        }
        let folders = scope.requestFolders
        task = Task { @MainActor [weak self, engine] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let result = await engine.query(q, limit: 8, folders: folders)
            guard !Task.isCancelled, let self else { return }
            switch result {
            case .success(let found):
                self.hits = found
                self.notice = found.isEmpty ? "No good matches" : ""
            case .failure(let error):
                self.hits = []
                self.notice = error.localizedDescription
            }
            self.selection = 0
        }
    }
}

/// The search panel's layout, in points. The header (the top row and its divider) and the footer (the key hints) are
/// pinned; the notice and the results sit between them, and only the results scroll, inside their own height. The panel's
/// height is computed from these numbers, so it always matches the content: no fitting-size measuring.
enum SearchLayout {
    static let topRow: CGFloat = 62
    static let hairline: CGFloat = 1
    static let footer: CGFloat = 38
    static let notice: CGFloat = 44   // room for two wrapped lines of the notice (12 pt)
    /// The "Best matches" label above the rows.
    static let sectionLabel: CGFloat = 28
    /// One result row: a 34 pt tile and at most two lines of text, plus its padding.
    static let row: CGFloat = 64
    static let listPadding: CGFloat = 8
    static let maxRows = 8
    /// The scope chip at the far right of the top row: its width, height, and its inset from the right and top edges.
    static let chipWidth: CGFloat = 118
    static let chipHeight: CGFloat = 24
    static let chipInset: CGFloat = 20

    static func headerHeight(notice: Bool) -> CGFloat {
        topRow + hairline + (notice ? self.notice : 0)
    }

    /// The list's height: the section label and its rows, but never more than `maxHeight` (the list then scrolls).
    /// Zero with no results.
    static func listHeight(rows: Int, maxHeight: CGFloat) -> CGFloat {
        guard rows > 0 else { return 0 }
        return min(sectionLabel + CGFloat(rows) * row + listPadding, maxHeight)
    }

    static func panelHeight(rows: Int, notice: Bool, maxHeight: CGFloat) -> CGFloat {
        headerHeight(notice: notice) + listHeight(rows: rows, maxHeight: maxHeight) + hairline + footer
    }

    /// About eight rows, or 60% of the screen's visible height, whichever is smaller.
    static func maxListHeight(screenVisibleHeight: CGFloat) -> CGFloat {
        min(sectionLabel + CGFloat(maxRows) * row + listPadding, (0.6 * screenVisibleHeight).rounded(.down))   // whole points: frames round too
    }
}

struct SearchView: View {
    @ObservedObject var model: SearchModel
    @ObservedObject var scope: FolderScope
    @FocusState private var fieldFocused: Bool
    /// The last pointer position over the results, in window coordinates: a change of it is movement.
    @State private var lastPointer: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            // Pinned header: the lens, the query on the glass (no field fill or outline), and the scope chip at the far right.
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
                TextField("Search your files by meaning", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24))
                    .foregroundStyle(Theme.ink)
                    .focused($fieldFocused)
                    .padding(.vertical, 4)   // no field fill or outline: the query sits on the one glass surface
                FolderScopeChip(scope: scope, focused: model.folderFocused, open: model.folderPopoverOpen,
                                onHover: { model.onFolderHover?($0) },
                                onClick: { model.onFolderClick?() })
            }
            .padding(.horizontal, 16)
            .frame(height: SearchLayout.topRow)
            Hairline()
            if !model.notice.isEmpty {
                Text(model.notice)   // prose: it wraps in full (up to two lines) and is never cut
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: SearchLayout.notice, alignment: .top)
            }
            // The results: the only part that scrolls. Up and Down keep the selected row in view.
            if !model.hits.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Best matches")
                                .font(.system(size: 11, weight: .semibold))
                                .textCase(.uppercase)
                                .tracking(0.4)
                                .foregroundStyle(Theme.muted)
                                .padding(.horizontal, 12)
                                .frame(height: SearchLayout.sectionLabel, alignment: .bottomLeading)
                            ForEach(Array(model.hits.enumerated()), id: \.element.id) { index, hit in
                                ResultRow(hit: hit, selected: index == model.selection, listFocused: model.listFocused)
                                    .frame(height: SearchLayout.row)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    // Hover selects only on real pointer movement: the window position must change. Rows
                                    // that scroll under a still pointer keep the selection the keyboard or the results set.
                                    .onContinuousHover(coordinateSpace: .global) { phase in
                                        guard case .active(let point) = phase, point != lastPointer else { return }
                                        lastPointer = point
                                        model.pointerMoved(toRow: index)
                                    }
                                    .onTapGesture {
                                        model.selection = index
                                        model.onOpenRow?(hit)
                                    }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, SearchLayout.listPadding / 2)
                    }
                    .frame(height: SearchLayout.listHeight(rows: model.hits.count, maxHeight: model.maxListHeight))
                    .onChange(of: model.selection) { _, selection in
                        proxy.scrollTo(selection)
                    }
                }
            }
            Hairline()
            // Pinned footer: the key hints. A drag handle like the header (see SearchController.inDragZone).
            HintRow()
                .frame(height: SearchLayout.footer)
        }
        .frame(width: 640, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassSurface(radius: 22)
        .onAppear { fieldFocused = true }
        .onChange(of: model.focusTick) { _, _ in fieldFocused = true }
        .onChange(of: model.folderFocused) { _, focused in fieldFocused = !focused && !model.listFocused }
        .onChange(of: model.listFocused) { _, focused in fieldFocused = !focused && !model.folderFocused }
    }
}

/// The footer's shortcuts: the key cap and what it does, right-aligned, quiet and muted.
struct HintRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            KeyHint(keys: "↩", action: "open")
            KeyHint(keys: "⌘↩", action: "show in Finder")
            KeyHint(keys: "Space", action: "preview")
            KeyHint(keys: "Esc", action: "close")
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
    }
}

/// One shortcut in the footer: a key cap and what it does.
struct KeyHint: View {
    let keys: String
    let action: String

    var body: some View {
        HStack(spacing: 5) {
            KeyCap(key: keys)
            // The label's lowercase sits 1.25 pt below the cap centre in the measured render; lifted to the cap's centre.
            Text(action).offset(y: -1)
        }
    }
}

struct ResultRow: View {
    let hit: Hit
    let selected: Bool
    let listFocused: Bool

    var body: some View {
        let url = URL(fileURLWithPath: hit.path)
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.chip)
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "doc.text").font(.system(size: 15)).foregroundStyle(Theme.muted))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // Shown only when the engine sends `similarity`. Rank score is not shown as relevance.
                    if let similarity = hit.similarity {
                        StrengthBar(level: Self.strength(similarity))
                    }
                    Text(url.deletingLastPathComponent().lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Text(hit.snippet)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Theme.selected : Color.clear))
    }

    /// Maps raw cosine similarity to 0...1 for the bar. Uncalibrated: 0.70 maps to empty, 0.95 to full.
    static func strength(_ similarity: Double) -> Double {
        min(max((similarity - 0.70) / 0.25, 0), 1)
    }
}

/// The match strength as three dots, from the similarity (never the raw score). Decorative; the level is on the label.
struct StrengthBar: View {
    let level: Double

    var body: some View {
        let lit = 1 + min(Int(level * 2.999), 2)
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(i < lit ? Theme.accent : Theme.edge).frame(width: 5, height: 5)
            }
        }
        .accessibilityLabel("Match strength")
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
    }
}

/// Quick Look preview of one file. Read-only.
final class QuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLook()
    private var url: URL?

    func toggle(_ url: URL) {
        if QLPreviewPanel.shared().isVisible { close() } else { preview(url) }
    }

    func preview(_ url: URL) {
        self.url = url
        let panel = QLPreviewPanel.shared()!
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { QLPreviewPanel.shared()?.orderOut(nil) }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as NSURL?
    }
}

/// Owns the floating panel: its place, show/hide, keyboard, the folder list, and dragging.
final class SearchController: NSObject, NSWindowDelegate {
    private let model: SearchModel
    private let panel: SearchPanel
    private let hosting: NSHostingView<SearchView>
    private var popover: FolderPopoverController?
    private var popoverPinned = false          // opened by a click or the keyboard: stays until closed
    private var exitWork: DispatchWorkItem?    // the hover grace: the list closes only if the pointer stays away
    private var saveWork: DispatchWorkItem?
    private var pressInPanel = false           // a mouse button went down on the panel: a drag may be under way
    private var dragStartMouse: NSPoint?       // screen point where a top-row press began (nil: not a drag area)
    private var dragStartOrigin = NSPoint.zero
    private var dragging = false
    private var monitors: [Any] = []
    private var cancellables = Set<AnyCancellable>()
    private let defaults: PrefStore

    /// Counters for the headless tests.
    private(set) var hideCount = 0
    private(set) var popoverOpenCount = 0
    private(set) var popoverCloseCount = 0
    private(set) var settingsOpenCount = 0

    init(engine: EngineManager, scope: FolderScope, defaults: PrefStore = AppPrefs.store) {
        self.defaults = defaults
        model = SearchModel(engine: engine, scope: scope)
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 64),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: true)
        hosting = NSHostingView(rootView: SearchView(model: model, scope: scope))
        super.init()

        panel.contentView = hosting   // the glass is the SwiftUI surface; the panel itself is clear
        panel.delegate = self
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Keep the panel's height matched to its content as results come and go.
        Publishers.Merge(model.$hits.map { _ in () }, model.$notice.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.resize() }
            .store(in: &cancellables)

        model.onFolderHover = { [weak self] inside in self?.folderHover(inside) }
        model.onFolderClick = { [weak self] in self?.folderClick() }
        model.onOpenRow = { [weak self] hit in self?.open(hit) }
        // Tab (or the keyboard) reaching the scope chip opens its list, pinned; leaving the chip closes it.
        model.$folderFocused.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] focused in focused ? self?.openPopover(pinned: true) : self?.closePopover() }
            .store(in: &cancellables)

        monitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            return self.mouse(event) ? nil : event
        } as Any)
    }

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    /// Shows the panel at the remembered place on the pointer's screen, or at the default place.
    func show() {
        model.reset()
        let screen = SearchPlacement.screen(holding: NSRect(origin: NSEvent.mouseLocation, size: .zero))
        model.maxListHeight = SearchLayout.maxListHeight(screenVisibleHeight: screen.visibleFrame.height)
        let size = NSSize(width: 640, height: SearchLayout.panelHeight(rows: model.hits.count, notice: !model.notice.isEmpty,
                                                                       maxHeight: model.maxListHeight))
        let origin = SearchPlacement.restoredOrigin(size: size, screen: screen, defaults: defaults)
            ?? SearchPlacement.defaultOrigin(size: size, in: screen.visibleFrame)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if Headless.enabled { Headless.makeInvisible(panel) }   // headless: transparent (its place is checked by the scope test)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        hideCount += 1
        closePopover()
        QuickLook.shared.close()
        panel.orderOut(nil)
    }

    var isPanelVisible: Bool { panel.isVisible }

    /// Sets the panel's height from the layout rules (see SearchLayout). The top edge stays where it is, so the header
    /// does not move while results arrive or leave, and a dragged place keeps its x and its top.
    private func resize() {
        let screen = SearchPlacement.screen(holding: panel.frame)
        model.maxListHeight = SearchLayout.maxListHeight(screenVisibleHeight: screen.visibleFrame.height)
        let height = SearchLayout.panelHeight(rows: model.hits.count, notice: !model.notice.isEmpty,
                                              maxHeight: model.maxListHeight)
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: 640, height: height)
        frame.origin.y = top - height
        panel.setFrame(frame, display: true, animate: false)
    }

    // MARK: - Focus and dragging

    func windowDidResignKey(_ notification: Notification) {
        // A drag that starts on the panel never dismisses it. Focus loss otherwise dismisses it, unless focus moved to our
        // own Quick Look panel.
        if pressInPanel { return }
        DispatchQueue.main.async { [weak self] in
            if !QLPreviewPanel.shared().isVisible { self?.hide() }
        }
    }

    /// After a drag, the place is remembered for this screen (after the drag settles).
    func windowDidMove(_ notification: Notification) {
        guard pressInPanel else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let screen = SearchPlacement.screen(holding: self.panel.frame)
            SearchPlacement.save(origin: self.panel.frame.origin, screen: screen, defaults: self.defaults)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// The top row's empty areas: the lens on the left and the margin on the right. The text field and the chip
    /// take their own clicks, so a double-click there is not a reset.
    func inResetZone(_ point: NSPoint) -> Bool {
        let content = panel.contentView?.bounds ?? .zero
        guard point.y >= content.height - SearchLayout.topRow else { return false }
        return point.x < 50 || point.x > content.width - 14
    }

    /// Double-click on the empty top row: forget the remembered place on this screen and go back to the default.
    func resetPosition() {
        let screen = SearchPlacement.screen(holding: panel.frame)
        SearchPlacement.clear(screen: screen, defaults: defaults)
        let size = panel.frame.size
        panel.setFrame(NSRect(origin: SearchPlacement.defaultOrigin(size: size, in: screen.visibleFrame), size: size), display: true)
    }

    /// Returns true when the event is consumed (a drag in progress).
    private func mouse(_ e: NSEvent) -> Bool {
        switch e.type {
        case .leftMouseDown:
            if e.window === panel {
                pressBegan(at: e.locationInWindow, screen: NSEvent.mouseLocation, clickCount: e.clickCount)
            } else if model.folderPopoverOpen, e.window !== popover?.panel {
                closePopover()   // a click anywhere else closes the folder list
            }
            return false
        case .leftMouseDragged:
            return dragged(to: NSEvent.mouseLocation)
        case .leftMouseUp:
            pressEnded()
            return false
        case .rightMouseDown:
            if model.folderPopoverOpen, e.window !== popover?.panel { closePopover() }
            return false
        default:
            return false
        }
    }

    /// The scope chip's rectangle in the panel's coordinates (a little larger than the chip, for the pointer).
    private func scopeChipRect(in content: NSRect) -> NSRect {
        NSRect(x: content.width - SearchLayout.chipInset - SearchLayout.chipWidth,
               y: content.height - (SearchLayout.topRow - SearchLayout.chipHeight) / 2 - SearchLayout.chipHeight,
               width: SearchLayout.chipWidth, height: SearchLayout.chipHeight).insetBy(dx: -4, dy: -4)
    }

    /// The header (the top row) and the footer (the key hints) are the drag area: anywhere on them, the field and the lens
    /// included, except the scope chip. A press on the results does not drag. A plain click still reaches the field; a
    /// drag does not select text.
    func inDragZone(_ point: NSPoint) -> Bool {
        let content = panel.contentView?.bounds ?? .zero
        if scopeChipRect(in: content).contains(point) { return false }
        let inHeader = point.y >= content.height - SearchLayout.topRow - SearchLayout.hairline
        let inFooter = point.y <= SearchLayout.footer + SearchLayout.hairline
        return inHeader || inFooter
    }

    private func pressBegan(at point: NSPoint, screen: NSPoint, clickCount: Int) {
        pressInPanel = true
        dragging = false
        dragStartMouse = nil
        if clickCount == 2, inResetZone(point) {   // double-click on the empty lens or margin: back to the default place
            resetPosition()
            return
        }
        if inDragZone(point) {
            dragStartMouse = screen
            dragStartOrigin = panel.frame.origin
        }
    }

    /// Moves the panel by the mouse's movement since the press. Returns true when it moved the panel (the event is then consumed).
    func dragged(to screen: NSPoint) -> Bool {
        guard let start = dragStartMouse else { return false }
        let dx = screen.x - start.x, dy = screen.y - start.y
        if !dragging && (abs(dx) < 3 && abs(dy) < 3) { return false }   // a click, not yet a drag
        dragging = true
        panel.setFrameOrigin(NSPoint(x: dragStartOrigin.x + dx, y: dragStartOrigin.y + dy))
        return true
    }

    private func pressEnded() {
        pressInPanel = false
        dragStartMouse = nil
        dragging = false
    }

    // MARK: - Folder list

    /// The scope chip on the screen: the list opens under it.
    private var folderAnchor: NSRect {
        let chip = scopeChipRect(in: NSRect(origin: .zero, size: panel.frame.size)).insetBy(dx: 4, dy: 4)
        return chip.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
    }

    /// Hover opens the list; leaving closes it after a 150 ms grace, so moving from the chip into the list does not flicker.
    private func folderHover(_ inside: Bool) {
        exitWork?.cancel()
        exitWork = nil
        if inside {
            if !model.folderPopoverOpen { openPopover(pinned: false) }
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.popoverPinned else { return }
            self.closePopover()
        }
        exitWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// A click toggles the list: opened by a click, it stays until the next click, Esc, or a click elsewhere.
    private func folderClick() {
        if model.folderPopoverOpen && popoverPinned { closePopover() } else { openPopover(pinned: true) }
    }

    private func openPopover(pinned: Bool) {
        if pinned { popoverPinned = true }
        guard !model.folderPopoverOpen else { return }
        if popover == nil {
            popover = FolderPopoverController(model: model, onHover: { [weak self] inside in self?.folderHover(inside) },
                                              onSettings: { [weak self] in self?.openSettings() })
        }
        popover?.show(below: folderAnchor, of: panel, animated: !Headless.enabled)
        if Headless.enabled, let p = popover?.panel { Headless.makeInvisible(p) }
        model.folderPopoverOpen = true
        popoverOpenCount += 1
    }

    /// The popover's Settings button: the list and the panel are dismissed, then Settings comes to front (the same window
    /// the menu's Settings item opens).
    private func openSettings() {
        hide()
        settingsOpenCount += 1
        SettingsWindow.shared.show()
    }

    private func closePopover() {
        guard model.folderPopoverOpen else { return }
        popover?.hide(animated: !Headless.enabled)
        model.folderPopoverOpen = false
        popoverPinned = false
        exitWork?.cancel()
        exitWork = nil
        popoverCloseCount += 1
    }

    // MARK: - Keyboard

    /// Returns true when the key event was consumed.
    private func handle(_ e: NSEvent) -> Bool {
        switch e.keyCode {
        case 53:                                   // Esc: the folder list first, then the panel
            if model.folderPopoverOpen { closePopover(); return true }
            hide()
            return true
        case 125:                                  // Down
            if model.folderFocused { model.moveFolderCursor(1) } else { model.move(1); previewIfOpen() }
            return true
        case 126:                                  // Up
            if model.folderFocused { model.moveFolderCursor(-1) } else { model.move(-1); previewIfOpen() }
            return true
        case 36, 76:                               // Return / keypad Enter
            if model.folderFocused { folderKey(); return true }
            guard let hit = model.selected else { return true }
            if e.modifierFlags.contains(.command) { reveal(hit) } else { open(hit) }
            return true
        case 48:                                   // Tab: field, scope chip, results, field
            model.cycleFocus()
            return true
        case 49 where model.folderFocused:         // Space works the folder list
            folderKey()
            return true
        case 49 where model.listFocused:           // Space previews when the results have focus
            if let hit = model.selected {
                QuickLook.shared.toggle(URL(fileURLWithPath: hit.path))
            }
            return true
        default:
            // Typing returns focus to the field; the key itself goes to the field.
            if (model.listFocused || model.folderFocused) && !e.modifierFlags.contains(.command) {
                model.listFocused = false
                model.folderFocused = false
            }
            return false
        }
    }

    /// Return or Space on the scope chip: open the list, or, with the list open, toggle the row under the cursor.
    private func folderKey() {
        if !model.folderPopoverOpen {
            openPopover(pinned: true)
        } else {
            model.activateFolderCursor()
        }
    }

    private func previewIfOpen() {
        guard QLPreviewPanel.shared().isVisible, let hit = model.selected else { return }
        QuickLook.shared.preview(URL(fileURLWithPath: hit.path))
    }

    private func open(_ hit: Hit) {
        NSWorkspace.shared.open(URL(fileURLWithPath: hit.path))
        hide()
    }

    private func reveal(_ hit: Hit) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)])
        hide()
    }

#if DEBUG
    // MARK: - Diagnostics (`--dump-ui`)

    /// The panel's view tree after layout, at the height `show()` gives it (the panel is never ordered in).
    func debugViewTree() -> [String] {
        sizeForDump()
        return UIDumpFormat.tree(panel.contentView)
    }

    /// The folder list's view tree after layout. Built if needed, never shown.
    func debugPopoverTree() -> [String] {
        let view = debugPopover()
        return UIDumpFormat.tree(view)
    }

    /// Renders the panel (and then the list) offscreen to a PNG. Nothing is shown.
    func debugSnapshot(panelTo panelPath: String, popoverTo popoverPath: String) -> Bool {
        sizeForDump()
        let panelOK = UIDumpFormat.png(panel.contentView, to: panelPath)
        let popoverOK = UIDumpFormat.png(debugPopover(), to: popoverPath)
        return panelOK && popoverOK
    }

    private func sizeForDump() {
        resize()
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    /// Test only: the panel's frame and its hosting view's frame, for the layout test.
    func testFrames() -> (panel: NSRect, hosting: NSRect, fitting: NSSize) {
        (panel.frame, hosting.frame, hosting.fittingSize)
    }

    /// Test only: sets results and applies the layout as a real result arrival does.
    func testSetResults(_ found: [Hit], notice: String) {
        model.testSetResults(found, notice: notice)
        resize()
    }

    /// Test only: renders the panel's content offscreen.
    /// Test only: the scope list's panel, for the real-window capture of the popover.
    var testPopoverPanel: NSPanel? { popover?.panel }
    /// Test only: opens the scope list as a click does.
    func testOpenPopover() { openPopover(pinned: true) }

    func testRender(to path: String) -> Bool {
        sizeForDump()
        return UIDumpFormat.png(panel.contentView, to: path)
    }

    /// Test only: the list's selection moves (Up/Down), which scrolls the list.
    func testMoveSelection(_ delta: Int) { model.move(delta) }

    private func debugPopover() -> NSView? {
        if popover == nil {
            popover = FolderPopoverController(model: model, onHover: { _ in }, onSettings: {})
        }
        guard let p = popover?.panel else { return nil }
        let height = max(p.contentView?.fittingSize.height ?? 80, 80)
        p.setFrame(NSRect(origin: p.frame.origin, size: NSSize(width: FolderPopoverController.width, height: height)), display: false)
        p.contentView?.layoutSubtreeIfNeeded()
        return p.contentView
    }

    // MARK: - Test hooks (headless tests only)

    /// Simulates a mouse button going down on the panel (a drag in progress).
    func testPressBegin() { pressInPanel = true }
    func testPressEnd() { pressInPanel = false }
    /// A press at a point of the panel (window coordinates), and the mouse moved to a screen point, as the monitor sees them.
    func testPress(at point: NSPoint, screen: NSPoint, clickCount: Int = 1) { pressBegan(at: point, screen: screen, clickCount: clickCount) }
    func testDrag(to screen: NSPoint) -> Bool { dragged(to: screen) }
    func testRelease() { pressEnded() }
#endif
    /// The panel's own frame, for the drag and placement tests.
    var testPanel: NSPanel { panel }
    var testHasDefaults: PrefStore { defaults }
    func testResignKey() { windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: panel)) }
    func testHoverEnter() { folderHover(true) }
    func testHoverExit() { folderHover(false) }
    func testFolderClick() { folderClick() }
    func testMoved() { windowDidMove(Notification(name: NSWindow.didMoveNotification, object: panel)) }
}
