import AppKit
import Carbon
import ServiceManagement
import SwiftUI

/// A sheet that a test hook can open straight away when Settings appears.
enum SettingsSheet { case uninstall, diagnostics }

/// Sizes a window to its SwiftUI content once. Windows do not follow the content's preferred size while they are open:
/// with `preferredContentSize` and a full-size content view (the unified glass titlebar), presenting a sheet changes the
/// safe area, the content reports a new preferred size, the window resizes, and the safe area changes again. AppKit then
/// throws "needs another Update Constraints in Window pass" (the uninstall sheet crash). Measuring once avoids the cycle.
func fitWindow<V: View>(_ window: NSWindow, _ host: NSHostingController<V>) {
    host.view.layoutSubtreeIfNeeded()
    let size = host.view.fittingSize
    guard size.width > 0, size.height > 0, window.contentView?.frame.size != size else { return }
    window.setContentSize(size)
}

/// A window of the redesign: a transparent titlebar over one glass surface that covers the whole window.
func unifiedWindow(_ w: NSWindow) {
    w.styleMask.insert(.fullSizeContentView)
    w.styleMask.insert(.miniaturizable)   // minimise works; zoom stays disabled because the windows are not resizable
    w.isMovableByWindowBackground = true  // the titlebar strip (and any background) drags the window
    w.titlebarAppearsTransparent = true
    w.titleVisibility = .hidden
    w.isOpaque = false
    w.backgroundColor = .clear
    WindowGlass.install(on: w)   // the window's glass: AppKit views sized to the whole frame, under the content
}

final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?
    private var host: NSHostingController<SettingsView>?
    private var keys: Any?

#if DEBUG
    /// Test only: the window's frame view (the titlebar and the content), for the window-look render.
    var testFrameView: NSView? { window?.contentView?.superview }
    /// Test only: the window closed and forgotten, so the next show builds it again (with the sheet to open).
    func testReset() { window?.close(); window = nil; host = nil }
    /// Test only: the window, for the frame checks of the tab switch.
    var testWindow: NSWindow? { window }
#endif

    /// Opens Settings. `tab` selects a tab first (the menu's Folders row asks for Folders; first launch asks for General).
    func show(open: SettingsSheet? = nil, tab: SettingsTab? = nil) {
        if let tab { SettingsNav.shared.setTab(tab) }
        if window == nil {
            let h = NSHostingController(rootView: SettingsView(autoOpen: open, nav: SettingsNav.shared,
                                                               welcome: OnboardingWindow.shared.model,
                                                               contentHeight: SettingsLayout.contentHeight(for: NSScreen.main)))
            h.sizingOptions = []   // the window keeps the height it is given: the content never resizes it
            host = h
            let w = AppWindow(contentViewController: h)
            w.styleMask = [.titled, .closable]
            unifiedWindow(w)
            w.title = "Settings"   // set once: no tab change touches the title or the toolbar
            w.setContentSize(SettingsLayout.windowSize(for: NSScreen.main))   // the one size, for every tab; set once
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            if Headless.enabled, let w = window { Headless.hide(w) }
            installKeys()
        }
        if !Headless.enabled { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
        growToFitOnce(open: open)
        clearInitialFocus(window)
        Headless.hideAllSoon()
    }

    /// The first time the window is shown, every tab is measured again in the window itself. If any tab is taller than the
    /// area, the window grows once, before the user can switch tabs. The size does not change after that.
    private var grownOnce = false
    private func growToFitOnce(open: SettingsSheet?) {
        guard let window, !grownOnce else { return }
        grownOnce = true
        let wanted = SettingsLayout.windowSize(for: window.screen ?? NSScreen.main)
        guard wanted.height > window.frame.height + 0.5 else { return }
        host?.rootView = SettingsView(autoOpen: open, nav: SettingsNav.shared, welcome: OnboardingWindow.shared.model,
                                      contentHeight: wanted.height - SettingsLayout.tabBarHeight)
        window.setContentSize(wanted)
    }

    /// Selects a tab (the tab bar, the keyboard, a test). Only the content changes: the window does not move or resize.
    func select(_ tab: SettingsTab) {
        SettingsNav.shared.setTab(tab)
    }

    /// Cmd+1, Cmd+2, Cmd+3 switch tabs; Esc and Cmd+W close the window (the window must be key).
    private func installKeys() {
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let w = self.window, event.window === w else { return event }
            if event.keyCode == 53 { w.close(); return nil }                       // Esc
            if event.modifierFlags.contains(.command) {
                if event.charactersIgnoringModifiers == "w" { w.close(); return nil }
                let tabs = SettingsTab.allCases
                if let digit = Int(event.charactersIgnoringModifiers ?? ""), digit >= 1, digit <= tabs.count {
                    self.select(tabs[digit - 1])
                    return nil
                }
            }
            return event
        }
    }
}

/// Records a hotkey: the next key combo with at least one of ⌘ ⌥ ⌃. Esc cancels.
enum HotKeyRecorder {
    private static var monitor: Any?

    static func start(_ done: @escaping (UInt32, UInt32, String?) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { (event: NSEvent) -> NSEvent? in
            if event.keyCode == 53 {
                HotKeyRecorder.stop()
                done(0, 0, nil)
                return nil
            }
            let mods = HotKey.carbonModifiers(event.modifierFlags)
            guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else { return nil }
            HotKeyRecorder.stop()
            done(UInt32(event.keyCode), mods, HotKey.label(for: event))
            return nil
        }
    }

    static func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }
}

/// Settings has one fixed size for every tab (the user's decision: the window never changes size on a tab switch). Its
/// height is the tallest tab at two folders listed, never taller than the display's visible height minus 80 pt; a tab
/// that is taller than that scrolls inside the tab area. Measured once, when the window is created.
enum SettingsLayout {
    static let width: CGFloat = 480
    /// Two buttons side by side in a section: the section's content (432 less 16 pt on each side) less one 8 pt gap.
    static let pairWidth: CGFloat = (width - 48 - 32 - 8) / 2
    /// The tab bar and its hairline (34 top, 50 buttons, 8 bottom, 0.5 hairline), rounded up.
    static let tabBarHeight: CGFloat = 93
    /// The tab swap: a short crossfade (instant with Reduce Motion).
    static let crossfade: TimeInterval = 0.12
    /// The folder list: a fixed area of three rows; more folders scroll inside it.
    static let folderRowHeight: CGFloat = 68
    static let folderRows = 3

    /// The most the window may be: the display's visible height minus 80 pt.
    static func maxWindowHeight(_ screen: NSScreen?) -> CGFloat { (screen?.visibleFrame.height ?? 800) - 80 }

    /// The tab area's height (the padding included): the tallest tab's natural height, capped.
    static func contentHeight(for screen: NSScreen?) -> CGFloat {
        let cap = (maxWindowHeight(screen) - tabBarHeight).rounded(.down)
        return min((tallestTabHeight() + bottomMargin).rounded(.up), cap)
    }

    /// The margin under the tallest tab: the area is that tab plus this, so no text sits on the window's bottom edge.
    static let bottomMargin: CGFloat = 24

    /// The window's size: the width, and the tab bar plus the tab area.
    static func windowSize(for screen: NSScreen?) -> NSSize {
        NSSize(width: width, height: tabBarHeight + contentHeight(for: screen))
    }

    /// A tab's natural height: its content and the 24 pt padding, as the real window lays it out. The tab is hosted in a
    /// 100 pt area, so it scrolls and its scroll view's document takes the content's own height. (A headless `sizeThatFits`
    /// reads less than the window shows: the clipped Advanced tab.)
    static func naturalTabHeight(_ tab: SettingsTab, welcome: OnboardingModel = OnboardingWindow.shared.model) -> CGFloat {
        let size = NSSize(width: width, height: tabBarHeight + 100)
        let host = NSHostingView(rootView: SettingsView(nav: SettingsNav(measuring: tab), welcome: welcome, contentHeight: 100)
            .frame(width: size.width, height: size.height))
        // The host lives in a window that is never shown: SwiftUI resolves the fit-or-scroll choice only inside a window.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        // SwiftUI lays the scroll content out on the run loop: a few passes let the document take its height.
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        let content = scrollDocumentHeight(in: host) ?? 0
        window.contentView = nil
        return content + 48   // the tab area's padding: 24 on each side
    }

    /// The document height of the first scroll view under `view` (the tab's scrolling content), if there is one.
    static func scrollDocumentHeight(in view: NSView) -> CGFloat? {
        if let scroll = view as? NSScrollView { return scroll.documentView?.frame.height }
        for child in view.subviews { if let found = scrollDocumentHeight(in: child) { return found } }
        return nil
    }

    /// General's language-model states, each as its own model: the window is sized for them. The failure with its
    /// details open is left out on purpose: it is the one state taller than the area, and it scrolls inside it.
    static func generalStates() -> [(name: String, model: OnboardingModel)] {
        let status = { (ready: Bool) in EngineStatus(["files": 0, "chunks": 0, "folders": [], "indexing": false, "model": "m",
                                                      "model_ready": ready, "folder_stats": []]) }
        let idle = OnboardingModel()
        idle.apply(status(false), rows: [])
        let ready = OnboardingModel()
        ready.apply(status(true), rows: [])
        let running = OnboardingModel()
        running.apply(status(false), rows: [])
        running.download = .running
        running.downloadedBytes = (212_000_000, 470_000_000)
        running.ease.seed(done: 212_000_000, total: 470_000_000)
        let failed = OnboardingModel()
        failed.apply(status(false), rows: [])
        failed.download = .failed(message: "The download stopped. Check the connection and try again.", detail: "URLError -1009")
        let retrying = OnboardingModel()
        retrying.apply(status(false), rows: [])
        retrying.download = .retrying(attempt: 2, max: 5)
        return [("missing", idle), ("ready", ready), ("downloading", running), ("retrying", retrying), ("failed", failed)]
    }

    /// The height the window's tab area is sized for: the tallest tab, General in its states, with two folders listed.
    static func tallestTabHeight() -> CGFloat {
        let general = generalStates().map { naturalTabHeight(.general, welcome: $0.model) }.max() ?? 0
        return max(general, naturalTabHeight(.folders), naturalTabHeight(.advanced))
    }

    /// Whether a tab's natural height needs its area to scroll.
    static func overflows(natural: CGFloat, area: CGFloat) -> Bool { natural > area + 0.5 }
}

/// The tabs of Settings, in the order of the toolbar.
enum SettingsTab: String, CaseIterable {
    case general, folders, advanced

    var title: String {
        switch self {
        case .general: return "General"
        case .folders: return "Folders"
        case .advanced: return "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .folders: return "folder"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

/// The selected tab, remembered across launches (UserDefaults), and changed from the menu, the keyboard or the toolbar.
final class SettingsNav: ObservableObject {
    static let key = "settingsTab"
    static let shared = SettingsNav(persist: true, tab: SettingsTab(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .general)
    @Published var tab: SettingsTab
    private let persist: Bool
    private init(persist: Bool, tab: SettingsTab) {
        self.persist = persist
        self.tab = tab
    }
    /// A measuring instance (the window measures each tab with one): it does not store the tab.
    convenience init(measuring tab: SettingsTab) { self.init(persist: false, tab: tab) }
    func setTab(_ new: SettingsTab) {
        tab = new
        if persist { UserDefaults.standard.set(new.rawValue, forKey: Self.key) }
    }
}

/// A section of settings: an optional small caps title above plain rows on the glass (no card; hairlines separate them).
struct SettingsSection<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Every row of Settings is this tall at least, with the same padding: 44 pt, so the groups read as one style.
enum SettingsRowMetrics {
    static let height: CGFloat = 44
    static let vertical: CGFloat = 8   // the controls are 28 pt at least (their hit area): 28 + 2 x 8 = 44
}

/// One row of a settings section: the title on the left, the control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.ink)
            Spacer(minLength: 12)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, SettingsRowMetrics.vertical)
        .frame(minHeight: SettingsRowMetrics.height, alignment: .center)
    }
}

/// The folder list, in Settings: each folder's name, its full path (middle-truncated), its file count and state, and Remove
/// on hover. The list is a fixed area of three rows; more folders scroll inside it, and fewer leave the rest empty.
struct FolderListBlock: View {
    @ObservedObject var model: OnboardingModel

    private var areaHeight: CGFloat { CGFloat(SettingsLayout.folderRows) * SettingsLayout.folderRowHeight }

    var body: some View {
        Group {
            if model.rows.isEmpty {
                Text("No folders yet.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            } else if Headless.enabled {   // captures draw the rows directly (a scroll view that was never ordered draws blank)
                rows
            } else {
                ScrollView(.vertical) { rows }
            }
        }
        .frame(maxWidth: .infinity, minHeight: areaHeight, maxHeight: areaHeight, alignment: .topLeading)
        .clipped()
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.rows) { row in
                FolderRowView(row: row, count: model.folderCounts[row.path] ?? "", indexLine: model.indexLine,
                              own: model.ownProgress[row.path])
                Hairline()
            }
        }
    }
}

/// Add folder and Index now, centred, and the model gate's line. These sit at the bottom of the Folders tab.
struct FolderActionsBlock: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {   // two equal slots across the tab's width
                ThemeButton("Add folder…", systemImage: "folder", role: .secondary, fullWidth: true) { model.chooseFolder() }
                    .disabled(!model.canChooseFolder)
                    .frame(width: (SettingsLayout.width - 48 - 8) / 2)
                    .layoutProbe("folders.add")
                ThemeButton("Index now", role: .secondary, fullWidth: true) { EngineManager.shared.send([["cmd": "index"]]) }
                    .disabled(!model.canChooseFolder || model.rows.isEmpty)
                    .frame(width: (SettingsLayout.width - 48 - 8) / 2)
                    .layoutProbe("folders.index")
            }
            .frame(maxWidth: .infinity, alignment: .center)
            if model.waitingCloud > 0 {   // quiet: the files are not a problem, the engine is only waiting for iCloud
                Text(CloudWaitLine.text(model.waitingCloud)).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            if model.rebuilding {
                Text(IndexNotice.rebuilding).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            if model.filesPartial > 0 {
                Text(IndexNotice.partial(model.filesPartial)).font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            if !model.canChooseFolder {
                Text("Download the language model first.").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
        }
        .layoutProbe("folders.lowest")
    }
}
