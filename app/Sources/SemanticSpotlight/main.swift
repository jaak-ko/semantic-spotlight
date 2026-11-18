import AppKit

/// Menu bar app: wires the engine supervisor, folder tracking, folder watcher, hotkey, menu and search panel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engine = EngineManager.shared
    private let tracker = FolderTracker.shared
    private let watcher = FolderWatcher.shared
    private var menu: StatusMenu!
    private var search: SearchController!
    private let folderScope = FolderScope()   // which folders the search uses (the excluded ones are stored)
    private var welcomeShownThisLaunch = false
    private var lastStatus: EngineStatus?
    private var lastMessage = "Starting engine…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Headless.startWatchdog()   // headless runs: no window of the app may reach a display, for the whole run
        installSheetFocusRule()    // every sheet opens with no control focused
        #if DEBUG
        if CommandLine.arguments.contains("--dump-ui"), Uninstall.testHome != nil {   // test only: print the UI states
            UIDump.run(engine: engine)
            exit(0)
        }
        #endif
        search = SearchController(engine: engine, scope: folderScope)
        menu = StatusMenu(host: Headless.enabled ? FakeStatusItem() : nil)   // headless: no status item on screen

        menu.onShow = { [weak self] in self?.search.show() }
        menu.onFolders = { SettingsWindow.shared.show(tab: .folders) }
        menu.onReindex = { [weak self] in self?.engine.send([["cmd": "index"]]) }
        menu.onRemove = { [weak self] path in self?.tracker.remove(path) }
        menu.onRetry = { [weak self] path in self?.tracker.retry(path) }
        menu.onSettings = { SettingsWindow.shared.show() }

        engine.onChange = { [weak self] status, message in
            guard let self else { return }
            self.lastStatus = status
            self.lastMessage = message
            Diagnostics.latestStatus = status
            Diagnostics.engineMessage = message
            self.search.setRebuilding(status?.rebuilding ?? false)
            self.tracker.apply(status)
            self.folderScope.reconcile(status)
            self.refresh()
            guard let status else { return }
            self.watcher.setFolders(status.folders)
            // Welcome screen: until finished, show it when the model or the first folder is missing.
            let needsSetup = !status.modelReady || status.folders.isEmpty
            if needsSetup, !OnboardingState.completed, !self.welcomeShownThisLaunch {
                self.welcomeShownThisLaunch = true
                OnboardingWindow.shared.show()
            }
        }
        tracker.onChange = { [weak self] in self?.refresh() }
        watcher.onChange = { [weak self] in self?.engine.send([["cmd": "index"]]) }

        HotKey.onPress = { [weak self] in self?.search.toggle() }
        if !HotKey.register(keyCode: Prefs.keyCode, modifiers: Prefs.modifiers) {
            NSLog("Semantic Spotlight: could not register hotkey \(Prefs.label)")
        }
        #if DEBUG
        if runTestHooks() { return }
        #endif
        engine.start()
        #if DEBUG
        if CommandLine.arguments.contains("--show-diagnostics-for-test"), Uninstall.testHome != nil {
            SettingsWindow.shared.show(open: .diagnostics)
        }
        #endif
    }

    #if DEBUG
    /// Test entry points (DEBUG builds, test roots only). Returns true when the real engine must not start: the menu
    /// tests drive the menu with simulated states, and the uninstall test shows only its sheet. The uninstall hook keeps
    /// the engine off so the fake tree is never written; the diagnostics hook starts it, so the report shows real status.
    private func runTestHooks() -> Bool {
        let args = CommandLine.arguments
        let testRun = Uninstall.testHome != nil
        if args.contains("--quit-menu-for-test"), testRun {   // press the menu's Quit by itself
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.menu.quit() }
        }
        if let i = args.firstIndex(of: "--stress-menu-for-test"), testRun {
            MenuStress.run(menu, steps: Int(args.dropFirst(i + 1).first ?? "") ?? 500)
        }
        if let i = args.firstIndex(of: "--headless-counter-for-test"), testRun {
            MenuStress.counter(menu, ticks: Int(args.dropFirst(i + 1).first ?? "") ?? 200)
        }
        if let i = args.firstIndex(of: "--theme-test-for-test"), testRun, i + 1 < args.count {
            let dir = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ThemeTests.run(dir: dir) }
        }
        if args.contains("--download-test-for-test"), testRun {   // the model download: progress, cancel, resume
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Task { @MainActor in
                    let failures = await DownloadTests.run()
                    MenuBarIcon.testLog("download test: done, \(failures) failures")
                    AppQuit.now()
                }
            }
        }
        if args.contains("--menu-icon-test-for-test"), testRun {   // the logo never changes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { MenuIconTests.run() }
        }
        if args.contains("--folders-test-for-test"), testRun {   // folder add and retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { FoldersTests.run() }
        }
        if args.contains("--layout-test-for-test"), testRun {   // search panel layout
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { LayoutTests.run() }
        }
        if args.contains("--onboarding-test-for-test"), testRun {   // welcome-window download states
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { OnboardingTests.run() }
        }
        if args.contains("--scope-test-for-test"), testRun {   // folder scope and panel
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { ScopeTests.run(self.search) }
        }
        if args.contains("--show-uninstall-for-test"), testRun {
            SettingsWindow.shared.show(open: .uninstall)
            return true
        }
        if args.contains("--chrome-test-for-test"), testRun {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ChromeTests.start() }
        }
        if let i = args.firstIndex(of: "--surface-capture-for-test"), testRun, i + 1 < args.count {
            let dir = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { GlassCaptureTests.startSurfaces(dir: dir) }
        }
        if let i = args.firstIndex(of: "--glass-capture-for-test"), testRun, i + 1 < args.count {
            let dir = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { GlassCaptureTests.start(dir: dir) }
        }
        let menuTests = ["--chrome-test-for-test", "--glass-capture-for-test", "--surface-capture-for-test", "--headless-counter-for-test", "--stress-menu-for-test", "--scope-test-for-test",
                         "--onboarding-test-for-test", "--layout-test-for-test", "--folders-test-for-test",
                         "--menu-icon-test-for-test", "--theme-test-for-test", "--download-test-for-test"]
        return menuTests.contains { args.contains($0) }
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }

    /// Pushes the latest status and folder rows to the menu and the welcome window.
    private func refresh() {
        let rows = tracker.rows(lastStatus)
        menu.update(lastStatus, lastMessage, rows: rows)
        menu.updateProgress(lastStatus)
        OnboardingWindow.shared.update(lastStatus, rows: rows)
    }

    private func addFolders() {
        guard lastStatus?.modelReady == true else { return }   // the menu item is disabled too
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Folder"
        panel.message = "Choose folders to index. Files are only read, never changed."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            // A failed add stays in the folder list, with Retry; no alert.
            tracker.add(url.path)
        }
    }
}

#if DEBUG
// Hidden test entries: uninstall against SS_UNINSTALL_HOME without starting the UI.
if CommandLine.arguments.contains("--uninstall-for-test") { exit(Uninstall.runForTest()) }
if CommandLine.arguments.contains("--list-inventory") { exit(Uninstall.listForTest()) }
#endif

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(Headless.enabled ? .prohibited : .accessory)
app.run()
