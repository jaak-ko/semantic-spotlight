import AppKit
import SwiftUI

/// State of the uninstall sheet. Sizes are measured on a background queue with a time budget, so the sheet
/// opens at once and shows "calculating…" for a size that is still being measured.
final class UninstallModel: ObservableObject {
    struct Row: Identifiable {
        let id: Int
        let title: String
        let subtitle: String
        var size: String
    }

    enum Phase: Equatable { case confirm, working, done }

    @Published var rows: [Row] = []
    @Published var details: [String] = []                // the scrollable list of what is removed; always capped
    @Published var notRemoved: [Uninstall.NotRemoved] = []   // app-created things still present after the run
    @Published var phase: Phase = .confirm
    @Published var summary: [String] = []                // short lines, shown after the removal
    @Published var partly = false
    @Published var reportText = ""                       // redacted; the only text the report buttons copy or save
    @Published var reportStatus = ""

    private var generation = 0

#if DEBUG
    /// Test only: the sheet opens on the summary state (for the surface captures); nothing is removed.
    static var testStartsDone = false
    /// Test only: which summary the test opens: "removed" (everything gone), "partial" (some left) or "working".
    static var testVariant = "removed"
    func testShowSummary() {
        phase = .done
        summary = ["Removed 12 items.", Uninstall.allRemovedSentence, "The app is still open. Quit it to finish."]
        notRemoved = []
        details = ["Removed: search index", "Removed: settings", "Removed: downloaded model"]
        partly = false
        reportText = ""
    }
    /// Test only: the variant the captures show (see testVariant).
    func testShowVariant() {
        switch UninstallModel.testVariant {
        case "working":
            phase = .working
        case "partial":
            testShowSummary()
            partly = true
            summary = ["Removed 9 items.", "2 things the app created are still present. The list below says how to finish each one.",
                       "The app is still open. Quit it to finish."]
            notRemoved = [Uninstall.NotRemoved(title: "Permission records macOS keeps for the app", path: nil,
                                               why: "macOS keeps these until they are reset.", command: Uninstall.tccCommand),
                          Uninstall.NotRemoved(title: "Login item", path: "~/Library/LaunchAgents/local.semanticspotlight.plist",
                                               why: "The system keeps it loaded until it is removed.",
                                               command: "launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/local.semanticspotlight.plist")]
        default:
            testShowSummary()
        }
    }
#endif

    /// Opens the confirmation: rows first, sizes arrive later.
    func begin() {
        generation += 1
        let gen = generation
        phase = .confirm
#if DEBUG
        if UninstallModel.testStartsDone { testShowVariant(); return }
#endif
        let groups = Uninstall.groups()
        rows = groups.enumerated().map { i, g in
            Row(id: i, title: g.title, subtitle: g.subtitle, size: "calculating…")
        }
        rows.append(Row(id: groups.count, title: "Permission records macOS keeps for the app",
                        subtitle: "reset with tccutil; no files", size: "reset"))
        details = Uninstall.capped(Uninstall.detailLines())
#if DEBUG
        if Uninstall.testHome != nil, Uninstall.env("SS_TEST_PRESS_QUIT") == "1", Uninstall.env("SS_UNINSTALL_AUTOCONFIRM") != "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.quit() }   // test only: Quit with the sheet open, nothing confirmed
        }
#endif
        DispatchQueue.global(qos: .userInitiated).async {
            for (i, g) in groups.enumerated() {
                let deadline = Date().addingTimeInterval(8)   // a slow size is shown as "more than …", never waited on
                var bytes: Int64 = 0
                var complete = true
                for path in g.paths {
                    let r = Uninstall.boundedSize(path, skip: g.skip, deadline: deadline)
                    bytes += r.bytes
                    complete = complete && r.complete
                }
                DispatchQueue.main.async { [weak self] in self?.setSize(i, bytes, complete, gen) }
            }
        }
    }

    private func setSize(_ index: Int, _ bytes: Int64, _ complete: Bool, _ gen: Int) {
        guard gen == generation, rows.indices.contains(index) else { return }   // a stale measurement is dropped
        let text = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        rows[index].size = complete ? text : "more than \(text)"
    }

    /// Removes everything, on a background thread. The sheet then shows the summary.
    func confirm() {
        guard phase == .confirm else { return }
        phase = .working
        FolderWatcher.shared.setFolders([])   // main thread only; stop watching before deleting
        DispatchQueue.global(qos: .userInitiated).async {
            let report = Uninstall.perform()
            DispatchQueue.main.async { self.finish(report) }
        }
    }

    private func finish(_ report: Uninstall.Report) {
        partly = !report.failed.isEmpty || !report.remaining.isEmpty
        summary = [
            "Removed \(report.removed.count) items.",
            report.notRemoved.isEmpty ? Uninstall.allRemovedSentence
                : "\(report.notRemoved.count) things the app created are still present. The list below says how to finish each one.",
            report.appStatus,
        ].compactMap { $0 }
        notRemoved = report.notRemoved
        details = Uninstall.capped(report.removed.map { "Removed: \($0)" })
        reportText = Diagnostics.uninstallReport(report, home: Uninstall.home)
        reportStatus = ""
        phase = .done
#if DEBUG
        if Uninstall.testHome != nil, Uninstall.env("SS_TEST_AUTOCOPY") == "1" { copyReport() }
        if Uninstall.testHome != nil, Uninstall.env("SS_TEST_AUTOSAVE") == "1" { saveReport() }
        if Uninstall.testHome != nil, Uninstall.env("SS_TEST_PRESS_QUIT") == "1" {   // test only: press Quit by itself
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.quit() }
        }
#endif
    }

    /// The Quit button, and the test that presses it. The one way out of the app.
    func quit() { AppQuit.now() }

    func copyReport() {
        Export.copy(reportText)
        reportStatus = "Copied to the clipboard."
    }

    func saveReport() {
        let name = "SemanticSpotlight-uninstall-report-\(Export.dayStamp()).txt"
        reportStatus = Export.save(reportText, defaultName: name) ? "Saved." : "Not saved."
    }
}

/// The confirmation and summary, shown as a sheet on the Settings window. Its size is fixed, and the only
/// long content is the scrollable lists, so layout cost does not grow with the size of the index.
struct UninstallSheet: View {
    @ObservedObject var model: UninstallModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch model.phase {
            case .confirm: confirmView
            case .working: workingView
            case .done: doneView
            }
        }
        .padding(24)
        .frame(width: 480)
        .glassSurface(radius: 20)
    }

    private var confirmView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uninstall \(Uninstall.appName)?").font(.system(size: 15, weight: .medium))
            Text("This removes the following. Your own files and folders are never touched, including the folders you indexed.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title)
                            Text(row.subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 12)
                        Text(row.size).monospacedDigit().foregroundStyle(Theme.muted)
                    }
                }
            }
            DetailList(lines: model.details, height: 90)
            Text(Uninstall.userFilesSentence)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("When removal finishes, quit the app: a helper then deletes the app itself. Anything the app created that cannot be removed is listed afterwards.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                Spacer()
                ThemeButton("Cancel", role: .secondary) { close() }
                    .keyboardShortcut(.cancelAction)
                ThemeButton("Uninstall", role: .destructiveSolid) { model.confirm() }
            }
        }
    }

    private var workingView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).padding(.bottom, 4)
            Text("Removing…").font(.system(size: 15, weight: .medium))
            Text("The search index, settings, the downloaded model and the app's preferences are being removed.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    /// The summary, centred: the status icon, the title and the lines, the lists, and the three buttons in one row.
    private var doneView: some View {
        VStack(spacing: 12) {
            Image(systemName: model.partly ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(model.partly ? Theme.warning : Theme.success)
                .padding(.bottom, 2)
            Text(model.partly ? "\(Uninstall.appName) is partly uninstalled." : "\(Uninstall.appName) is uninstalled.")
                .font(.system(size: 15, weight: .medium))
                .multilineTextAlignment(.center)
            ForEach(model.summary, id: \.self) { line in
                Text(line)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !model.notRemoved.isEmpty {
                Text("Not removed, and how to finish it yourself")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.top, 4)
                NotRemovedBox(entries: model.notRemoved, height: 180)
            }
            DetailList(lines: model.details, height: 84, centred: true)
            Text(Uninstall.userFilesSentence)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: UninstallSheet.buttonGap) {
                // fullWidth fills each slot (a label alone would keep its own width): three equal slots and two gaps.
                ThemeButton("Copy report", role: .secondary, fullWidth: true) { model.copyReport() }
                    .frame(width: UninstallSheet.buttonWidth)
                    .layoutProbe("summary.copy")
                ThemeButton("Save report…", role: .secondary, fullWidth: true) { model.saveReport() }
                    .frame(width: UninstallSheet.buttonWidth)
                    .layoutProbe("summary.save")
                ThemeButton("Quit", role: .primary, fullWidth: true) { model.quit() }   // "Quit Semantic Spotlight" is wider than a slot
                    .keyboardShortcut(.defaultAction)
                    .frame(width: UninstallSheet.buttonWidth)
                    .layoutProbe("summary.quit")
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
            Text(model.reportStatus)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .frame(height: 16)
        }
        .frame(maxWidth: .infinity)
    }

    /// The sheet's content width (480 less 24 pt on each side) and the gap between buttons.
    static let contentWidth: CGFloat = 432
    static let buttonGap: CGFloat = 8
    /// The three summary buttons share one width: (content - 2 gaps) / 3, so the row fills the content and is centred.
    static let buttonWidth: CGFloat = (contentWidth - 2 * buttonGap) / 3
}

/// The "Not removed" list: for each entry, what it is, its path (shown with ~ for the home folder), why it stays,
/// and the command or Finder step that finishes the job. A fixed-height scroll box.
struct NotRemovedBox: View {
    let entries: [Uninstall.NotRemoved]
    let height: CGFloat

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .center, spacing: 12) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, e in
                    VStack(alignment: .center, spacing: 4) {
                        Text(e.title).font(.system(size: 13, weight: .semibold)).multilineTextAlignment(.center)
                        if let p = e.path {
                            Text((p as NSString).abbreviatingWithTildeInPath)
                                .font(.system(size: 11, design: .monospaced))
                                .multilineTextAlignment(.center)
                                .textSelection(.enabled)
                        }
                        Text("Why: \(e.why)").font(.system(size: 11)).foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        if let c = e.command {
                            Text("To finish: \(c)")
                                .font(.system(size: 11, design: .monospaced))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
        }
        .frame(height: height)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// A fixed-height scrolling list. Lines are never laid out all at once beyond what is visible.
struct DetailList: View {
    let lines: [String]
    var height: CGFloat = 160
    /// Centred lines (the summary's list); otherwise left-aligned (the confirmation's list).
    var centred = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: centred ? .center : .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(centred ? .center : .leading)
                        .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity)
        }
        .frame(height: height)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
    }
}
