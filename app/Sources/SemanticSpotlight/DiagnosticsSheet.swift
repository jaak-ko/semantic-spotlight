import SwiftUI

/// The diagnostics preview. The text is built in the background and shown before anything is copied or saved.
final class DiagnosticsModel: ObservableObject {
    @Published var text = "Collecting…"
    @Published var ready = false
    @Published var status = ""

    /// Whether the text shown was made from a snapshot that had the engine's status, and how many times it was made again.
    private var snapshotHadStatus = false
    private var remakes = 0

    /// Opens the sheet: the text is made from a fresh snapshot. A sheet opened before the engine's first status shows the
    /// text again once the status is known (bounded), so Copy and Save never carry "Starting engine…" by mistake.
    func begin() {
        remakes = 0
        make()
    }

    private func make() {
        ready = false
        text = "Collecting…"
        status = ""
        var input = Diagnostics.snapshot()   // main thread: engine state, login item, hotkey
        snapshotHadStatus = input.status != nil
        DispatchQueue.global(qos: .userInitiated).async {
            input.config = Diagnostics.readConfig(home: input.home)
            Diagnostics.readLogs(into: &input)
            let text = Diagnostics.render(input)
            DispatchQueue.main.async {
                self.text = text
                self.ready = true
                self.settle()
                #if DEBUG
                self.autoActions()
                #endif
            }
        }
    }

    /// The status is known now but the text was made without it: make it again. The status is not known yet: look again
    /// in a second (up to a minute).
    private func settle() {
        let known = Diagnostics.latestStatus != nil
        guard known != snapshotHadStatus || !known, remakes < 60 else { return }
        remakes += 1
        if known {
            make()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.make() }
        }
    }

#if DEBUG
    /// Test only (needs SS_UNINSTALL_HOME): copy and save once the text carries the engine's status.
    private func autoActions() {
        guard Uninstall.testHome != nil, snapshotHadStatus || remakes >= 60 else { return }
        if Uninstall.env("SS_TEST_AUTOCOPY") == "1" { copy() }
        if Uninstall.env("SS_TEST_AUTOSAVE") == "1" { save() }
    }
#endif

    func copy() {
        Export.copy(text)
        status = "Copied to the clipboard."
    }

    func save() {
        let name = "SemanticSpotlight-diagnostics-\(Export.dayStamp()).txt"
        status = Export.save(text, defaultName: name) ? "Saved." : "Not saved."
    }
}

/// The diagnostics sheet, on the Settings window. Its only long content is the fixed-height scroll box.
struct DiagnosticsSheet: View {
    @ObservedObject var model: DiagnosticsModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Diagnostics").font(.system(size: 15, weight: .medium))
            Text("Read this before you send it. It contains no file names, search queries or file contents. Paths are shortened, and e-mail addresses are removed. Nothing is sent automatically.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(model.text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(height: 260)
            .overlay(alignment: .top) { Hairline() }
            .overlay(alignment: .bottom) { Hairline() }
            HStack(spacing: 8) {
                Text(model.status).font(.system(size: 12)).foregroundStyle(Theme.muted)
                Spacer()
                ThemeButton("Close", role: .secondary) { close() }
                    .keyboardShortcut(.cancelAction)
                ThemeButton("Save File…", role: .secondary) { model.save() }
                    .disabled(!model.ready)
                ThemeButton("Copy", role: .primary) { model.copy() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.ready)
            }
        }
        .padding(24)
        .frame(width: 480)
        .glassSurface(radius: 20)
    }
}
