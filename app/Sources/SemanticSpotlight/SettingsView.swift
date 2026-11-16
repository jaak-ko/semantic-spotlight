import AppKit
import ServiceManagement
import SwiftUI

/// Settings: a preferences window with a tab bar (General, Folders, Advanced). Every tab shares one fixed tab area
/// (SettingsLayout): the window never changes size; a tab switch swaps the content inside the area.
struct SettingsView: View {
    var autoOpen: SettingsSheet? = nil
    @ObservedObject var nav: SettingsNav
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The welcome page's model: Settings shows the same language model and folder state, and acts on the same model.
    @ObservedObject var welcome: OnboardingModel
    /// The height of the tab area, padding included. Nil measures each tab's natural height (SettingsLayout).
    var contentHeight: CGFloat? = nil
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var recording = false
    @State private var hotkey = Prefs.label
    @State private var error = ""
    @State private var showUninstall = false
    @StateObject private var uninstall = UninstallModel()   // the test flag UninstallModel.testStartsDone opens the summary
    @State private var showDiagnostics = false
    @StateObject private var diagnostics = DiagnosticsModel()

    /// The toolbar: one button per tab, icon above the label, centred, like the preferences of other Mac apps.
    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(SettingsTab.allCases, id: \.self) { t in
                ThemeButton(role: t == nav.tab ? .secondary : .quiet, size: .regular, action: { select(t) }) {
                    VStack(spacing: 4) {
                        Image(systemName: t.symbol).font(.system(size: 18, weight: .regular))
                        Text(t.title).font(.system(size: 11, weight: .medium))
                    }
                    .frame(width: 92, height: 50)
                }
                .accessibilityLabel(t.title)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 34)   // below the traffic lights and the transparent titlebar
        .padding(.bottom, 8)
    }

    private func select(_ t: SettingsTab) {
        guard t != nav.tab else { return }
        nav.setTab(t)
    }

    /// The tab's content in the fixed area: as it is when it fits (its footer pinned to the bottom), and in a scroll view
    /// when it does not, so nothing can be clipped (larger text, a smaller screen). Measuring (no fixed area) is never
    /// wrapped: the tab's own height is what is measured.
    @ViewBuilder private func scrolling<V: View>(_ tab: V) -> some View {
        if contentHeight != nil {
            ViewThatFits(in: .vertical) {
                tab
                ScrollView(.vertical) { tab }
            }
        } else {
            tab
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Hairline()
            Group {   // the swap: a crossfade of the content only (0.12 s; instant with Reduce Motion); nothing else moves
                switch nav.tab {
                case .general: scrolling(generalTab).transition(.opacity)
                case .folders: scrolling(foldersTab).transition(.opacity)
                case .advanced: scrolling(advancedTab).transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: SettingsLayout.crossfade), value: nav.tab)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(width: SettingsLayout.width, height: contentHeight, alignment: .topLeading)
            .clipped()
        }
        // Measuring (no fixed height): each tab takes its ideal height, not the greatest proposal (the spacers would grow).
        .fixedSize(horizontal: false, vertical: contentHeight == nil)
        // the window's glass is WindowGlass (installed with the window), not a SwiftUI background
        .sheet(isPresented: $showUninstall) {
            UninstallSheet(model: uninstall, close: { showUninstall = false })
                .interactiveDismissDisabled(uninstall.phase == .working)
        }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsSheet(model: diagnostics, close: { showDiagnostics = false })
        }
        .onAppear {
            switch autoOpen {
            case .uninstall?:
                openUninstall()
#if DEBUG
                // Test only: confirm without a click, so the destructive path can run against a fake HOME.
                if Uninstall.testHome != nil, ProcessInfo.processInfo.environment["SS_UNINSTALL_AUTOCONFIRM"] == "1" {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { uninstall.confirm() }
                }
#endif
            case .diagnostics?:
                openDiagnostics()
            case nil:
                break
            }
        }
    }

    // General: the language model, launch at login, the hotkey, the engine, and the privacy note.
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            // One group, one header, four rows of one style: the language model first, then startup, hotkey and engine.
            SettingsSection(title: "General") {
                LanguageModelRow(model: welcome)
                Hairline().padding(.leading, 16)
                SettingsRow(title: "Launch at login") {
                    Toggle("", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .focusEffectDisabled()   // no focus glow on open: the ring is for keyboard use only
                }
                .layoutProbe("general.launch")
                Hairline().padding(.leading, 16)
                SettingsRow(title: "Search hotkey") {
                    ThemeButton(role: .secondary, size: .compact) { startRecording() } label: {
                        KeyCap(key: recording ? "Press a shortcut… (Esc cancels)" : hotkey)
                    }
                }
                .layoutProbe("general.hotkey")
                Hairline().padding(.leading, 16)
                SettingsRow(title: "Engine") {
                    // One line, middle-truncated in a bounded column; the full path is in the tooltip and the Copy menu.
                    let path = EngineManager.engineBinary() ?? "not found"
                    Text(path)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 240, alignment: .trailing)
                        .help(path)
                        .contextMenu {
                            copyMenuItem("Copy path") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string) }
                        }
                }
            }
            Text("Everything runs on this Mac. The app makes no network connections and sends no telemetry.")
                .layoutProbe("general.privacy")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)   // prose wraps in full: it is never cut
                .padding(.horizontal, 12)
            if !error.isEmpty {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).padding(.horizontal, 12)
            }
        }
    }

    // Folders: the list (hover Remove) in its fixed area, then Add folder and Index now pinned at the tab's bottom.
    private var foldersTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "Folders") {
                FolderListBlock(model: welcome).padding(14)
            }
            Spacer(minLength: 0)
            FolderActionsBlock(model: welcome)
        }
    }

    // Advanced: diagnostics, uninstall, and the version line at the bottom.
    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSection(title: "Diagnostics") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Builds a text report for a support request. It is shown for review first; nothing is sent automatically.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {   // two equal slots, centred in their section (the text above stays left)
                        ThemeButton("Copy diagnostics…", role: .secondary, fullWidth: true) { openDiagnostics() }
                            .frame(width: SettingsLayout.pairWidth)
                            .layoutProbe("diagnostics.copy")
                        ThemeButton("Save diagnostics file…", role: .secondary, fullWidth: true) { openDiagnostics() }
                            .frame(width: SettingsLayout.pairWidth)
                            .layoutProbe("diagnostics.save")
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(16)
            }
            SettingsSection(title: "Uninstall") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Removes the search index, settings, downloaded model, preferences and the app itself. Your own files and indexed folders are never touched.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        ThemeButton("Uninstall Semantic Spotlight…", role: .destructive) { openUninstall() }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(16)
            }
            Spacer(minLength: 16)   // the version line sits at the bottom of the tab, 16 pt above its edge at least
            Text(BuildInfo.line)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .center)
                .layoutProbe("advanced.version")
        }
    }

    private func openUninstall() {
        uninstall.begin()
        showUninstall = true
    }

    private func openDiagnostics() {
        diagnostics.begin()
        showDiagnostics = true
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = ""
        } catch {
            self.error = "Could not change login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func startRecording() {
        recording = true
        HotKeyRecorder.start { code, mods, label in
            recording = false
            guard let label else { return }
            Prefs.saveHotKey(code: code, modifiers: mods, label: label)
            if HotKey.register(keyCode: code, modifiers: mods) {
                hotkey = label
                error = ""
            } else {
                error = "\(label) is taken by another app or the system. Keeping the previous hotkey."
                HotKey.register(keyCode: Prefs.keyCode, modifiers: Prefs.modifiers)
            }
        }
    }
}
