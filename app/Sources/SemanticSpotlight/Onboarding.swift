import AppKit
import Combine
import SwiftUI

/// Whether the user has finished the welcome screen (remembered across launches).
enum OnboardingState {
    private static let key = "onboardingCompleted"
    static var completed: Bool {
        get { AppPrefs.store.bool(forKey: key) }
        set { AppPrefs.store.set(newValue, forKey: key) }
    }
}

/// Events from `semsearch fetch-model`: one JSON object per stdout line.
private enum FetchEvent {
    case progress(done: Int, total: Int, speed: Double?)
    case retry(attempt: Int, max: Int)
    case done
    /// The engine stopped on a cancel (SIGTERM): its partial files stay, the next download resumes them.
    case cancelled(done: Int, total: Int)
    /// `message` is the friendly line; `detail` the technical text. Old engines send only `message`, which is then the
    /// technical text (detail nil).
    case error(message: String?, detail: String?)

    init?(line: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let kind = obj["event"] as? String else { return nil }
        switch kind {
        case "progress":
            // Old engines send no speed: the bar then eases on the bytes alone.
            self = .progress(done: obj["done"] as? Int ?? 0, total: obj["total"] as? Int ?? 0,
                             speed: (obj["speed"] as? NSNumber)?.doubleValue)
        case "cancelled":
            self = .cancelled(done: obj["done"] as? Int ?? 0, total: obj["total"] as? Int ?? 0)
        case "retry":
            self = .retry(attempt: obj["attempt"] as? Int ?? 1, max: obj["max"] as? Int ?? 5)
        case "done":
            self = .done
        case "error":
            self = .error(message: obj["message"] as? String, detail: obj["detail"] as? String)
        default:
            return nil
        }
    }
}

final class OnboardingModel: ObservableObject {
    enum Download: Equatable {
        case idle
        case running
        case retrying(attempt: Int, max: Int)   // the engine is trying again: calm, not an error
        case failed(message: String, detail: String)
        case done
        /// Stopped by the user: not an error, not retried. The partial download stays; "Resume download" continues it.
        case cancelled(done: Int, total: Int)
    }

    /// The line shown for a failure whose engine sent no friendly message (old engines, a crash of the helper).
    static let genericFailure = "The download did not finish. Try again."
    /// The technical detail is kept short: it is shown in a fixed-height box and copied on request.
    static let maxDetailLength = 2000

    @Published var modelReady = false
    @Published var rows: [FolderRow] = []
    @Published var hasFolder = false
    @Published var download: Download = .idle
    /// The engine is checking an installed model (`model_verifying`): neutral "Checking language model…", no Download.
    @Published var verifying = false
    /// The eased bar's value (the bar reads only this; see DownloadEase).
    let ease = DownloadEase()
    /// The download's byte counts from the engine (0 until the first progress event).
    @Published var downloadedBytes: (done: Int, total: Int) = (0, 0)
    /// Whether the technical details are open under a failure. Closed after each new attempt.
    @Published var detailsExpanded = false
    /// The file count of each folder ("6 files"), from the engine's folder stats (Settings and the welcome list show it).
    @Published var folderCounts: [String: String] = [:]
    /// "15 of 309" while the engine counts an indexing run; empty otherwise.
    @Published var indexLine = ""
    /// Each folder's own progress for the Folders tab (empty on an older engine or when idle). Run-wide numbers stay in indexLine.
    @Published var ownProgress: [String: FolderProgress] = [:]
    /// Files in iCloud the engine is waiting to download (0 when none).
    @Published var waitingCloud = 0

    private var process: Process?
    private var finished = false

    /// Finish is offered only when there is something to search with.
    var canFinish: Bool { modelReady && hasFolder }

    /// A folder can be added only once the language model is installed: until then the engine has nothing to index with.
    var canChooseFolder: Bool { modelReady }

    /// Called on every engine status poll. Assigns only on change to avoid needless redraws.
    func apply(_ status: EngineStatus?, rows newRows: [FolderRow]) {
        if rows != newRows { rows = newRows }
        guard let status else { return }
        let ready = status.modelReady || download == .done
        if modelReady != ready { modelReady = ready }
        // While the engine checks an installed model, the page says so: no Download button, the folder gate stays closed.
        let checking = status.modelVerifying && !ready
        if verifying != checking { verifying = checking }
        if hasFolder != !status.folders.isEmpty { hasFolder = !status.folders.isEmpty }
        // The folder rows' right side: the file count per folder, and the run's count while the engine indexes.
        let counts = status.folderStats.mapValues { "\($0) files" }
        if folderCounts != counts { folderCounts = counts }
        let line = status.determinate ? "\(status.done) of \(status.total)" : ""
        if indexLine != line { indexLine = line }
        let own = status.ownFolderProgress
        if ownProgress != own { ownProgress = own }
        if waitingCloud != status.waitingCloud { waitingCloud = status.waitingCloud }
    }

    /// The download's child process id while it runs (nil otherwise): tests check it is gone after a cancel.
    var childProcessID: pid_t? { process?.processIdentifier }
    /// The helper the download runs instead of the engine's (tests point it at the fake fetch script).
    static var testBinary: String?
    /// Set when the user asks to cancel: the child then ends on SIGTERM and its own cancelled line is the end.
    private var cancelRequested = false
    private var cancelledEvent = false
    /// How long a cancelled download may take to say so before it is killed (SIGKILL).
    static let cancelGrace: TimeInterval = 1.5

    /// Runs `semsearch fetch-model`. Only called from the button, so this is the sole network use. A cancelled download
    /// resumes by running it again: the engine keeps the partial files and continues from them.
    func fetchModel() {
        if case .running = download { return }
        if case .retrying = download { return }
        guard let bin = OnboardingModel.testBinary ?? EngineManager.engineBinary() else {
            download = .failed(message: "The engine is missing from this app. Reinstall the app.",
                               detail: "No engine executable was found in the app bundle or the development checkout.")
            return
        }
        // A resumed download continues from where it stopped: the bar shows that value at once.
        ease.seed(done: downloadedBytes.done, total: downloadedBytes.total)
        download = .running
        finished = false
        cancelRequested = false
        cancelledEvent = false
        detailsExpanded = false

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["fetch-model"]
        p.currentDirectoryURL = URL(fileURLWithPath: bin).deletingLastPathComponent()
        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        var buffer = Data()
        out.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                if let event = FetchEvent(line: line) {
                    DispatchQueue.main.async { self?.handle(event) }
                }
            }
        }
        p.terminationHandler = { [weak self] proc in
            let stderr = (try? err.fileHandleForReading.readToEnd()) ?? Data()
            let stderrText = String(data: stderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                if self.process === proc { self.process = nil }
                guard !self.finished else { return }
                self.finished = true
                if self.cancelRequested {   // the child ended on the cancel without its own line (it was killed)
                    self.download = .cancelled(done: self.downloadedBytes.done, total: self.downloadedBytes.total)
                    return
                }
                self.download = .failed(message: "The download stopped unexpectedly. Try again.",
                                        detail: Self.clipped("exit \(proc.terminationStatus)\n\(stderrText)"))
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            download = .failed(message: "The engine could not be started. Reinstall the app.",
                               detail: Self.clipped(error.localizedDescription))
        }
    }

    /// Cancel: SIGTERM to the download. The engine keeps its partial files and prints a cancelled line; if it has not
    /// printed one within `cancelGrace`, the process is killed (SIGKILL). A cancel is not an error and is never retried.
    func cancelDownload() {
        guard let p = process, p.isRunning, !cancelRequested else { return }
        cancelRequested = true
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cancelGrace) { [weak self] in
            guard let self, self.cancelRequested, !self.cancelledEvent, p.isRunning else { return }
            kill(pid, SIGKILL)
        }
    }

    /// Keeps the technical text bounded.
    static func clipped(_ text: String) -> String {
        text.count > maxDetailLength ? String(text.prefix(maxDetailLength)) + "…" : text
    }

    /// The clock the progress throttle reads (tests replace it with an injected time).
    var clock: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }
    private var lastProgressAt: TimeInterval = -.infinity
    /// Progress is published at most 4 times a second (the last value of a burst always lands when the download ends).
    static let progressInterval: TimeInterval = 0.25
    /// The number of progress publishes made so far (tests count them).
    private(set) var progressPublishes = 0

    /// One progress tick from the download: throttled, so the view and the window are not re-laid out every event.
    func progressTick(done: Int, total: Int) {
        let now = clock()
        guard now - lastProgressAt >= Self.progressInterval || (total > 0 && done >= total) else { return }
        lastProgressAt = now
        progressPublishes += 1
        if case .retrying = download { download = .running }   // the attempt went through
        downloadedBytes = (done, total)
    }

    private func handle(_ event: FetchEvent) {
        // After a cancel only the child's end counts: its progress, retry and error lines are not shown.
        if cancelRequested {
            switch event {
            case .progress, .retry, .error: return
            case .cancelled, .done: break
            }
        }
        switch event {
        case .progress(let done, let total, let speed):
            ease.report(done: done, total: total, speed: speed ?? 0)
            progressTick(done: done, total: total)
        case .retry(let attempt, let max):
            download = .retrying(attempt: attempt, max: max)
        case .cancelled(let done, let total):
            cancelledEvent = true
            finished = true
            if total > 0 { downloadedBytes = (done, total) }   // the engine's own count, when it sent one
            download = .cancelled(done: downloadedBytes.done, total: downloadedBytes.total)
        case .done:
            finished = true
            download = .done
            modelReady = true
            // The daemon loads the model at startup. Tests never start the real engine.
            if Uninstall.testHome == nil { EngineManager.shared.restartEngine() }
        case .error(let message, let detail):
            finished = true
            if let detail {
                download = .failed(message: message ?? Self.genericFailure, detail: Self.clipped(detail))
            } else {
                // Old contract: the only text is the technical one.
                download = .failed(message: Self.genericFailure, detail: Self.clipped(message ?? "Unknown error"))
            }
        }
    }

    /// Opens NSOpenPanel and registers the chosen folder. Results show in the folder rows.
    func chooseFolder() {
        guard canChooseFolder else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Index Folder"
        panel.message = "Choose a folder to index. Files are only read, never changed."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FolderTracker.shared.add(url.path)
    }
}

/// The welcome window's four states, in order: the model is missing; it is downloading (or retrying, or failed); the
/// model is ready and no folder is indexed yet; a folder is indexed and the window can finish.
enum OnboardingStage: Int, CaseIterable {
    case download, downloading, ready, indexed

    /// The current dot of the three progress dots: the first two states share the first dot.
    var dot: Int {
        switch self {
        case .download, .downloading: return 0
        case .ready: return 1
        case .indexed: return 2
        }
    }
}

extension OnboardingModel {
    var stage: OnboardingStage {
        guard modelReady else {
            if case .idle = download, !verifying { return .download }   // while checking, not "download": nothing to offer
            return .downloading
        }
        return hasFolder ? .indexed : .ready
    }
}

/// The language model on the welcome page: one fixed slot holds the button, which becomes the progress bar (with Cancel
/// beside its numbers) and then the ready line. Under it, a caption in a reserved height: the progress numbers in a fixed
/// mono slot; messages and errors wrap in full, never cut. A paused download offers "Resume download".
struct LanguageModelBlock: View {
    @ObservedObject var model: OnboardingModel
    static let slot: CGFloat = 38          // a button, a progress bar and a ready line all fit this one slot
    static let captionHeight: CGFloat = 16
    static let messageHeight: CGFloat = 46   // three lines of 12 pt, the most a message needs
    static let detailsHeight: CGFloat = 72   // the technical details, scrollable, when they are shown

    var body: some View {
        VStack(spacing: 6) {
            Text("Language model").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
            modelSlot
                .frame(maxWidth: .infinity, minHeight: Self.slot, maxHeight: Self.slot)
            caption
        }
    }

    private var isReady: Bool { model.modelReady || model.download == .done }
    /// An installed model is being checked: the neutral line, never the Download button.
    private var checking: Bool { model.verifying && !isReady && model.download == .idle }

    @ViewBuilder private var caption: some View {
        switch model.download {
        case .failed(let message, let detail) where !isReady:
            VStack(spacing: 6) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: Self.messageHeight, alignment: .top)
                ThemeButton(model.detailsExpanded ? "Hide details" : "Show details", role: .tertiary, size: .compact) {
                    model.detailsExpanded.toggle()
                }
                if model.detailsExpanded {
                    ScrollView(.vertical) {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .frame(height: Self.detailsHeight)
                    .overlay(alignment: .top) { Hairline() }
                }
            }
        case .running, .retrying:
            // The numbers in a fixed mono slot beside Cancel: the line never reflows as they change.
            HStack(spacing: 10) {
                Text(modelCaption)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .frame(width: ProgressSlot.width, height: Self.captionHeight)
                DownloadCancelButton(model: model)
            }
        case .cancelled(let done, let total):
            Text(pausedCaption(done: done, total: total))
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: Self.messageHeight, alignment: .top)
        default:
            Text(modelCaption)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: Self.messageHeight, alignment: .top)
        }
    }

    @ViewBuilder private var modelSlot: some View {
        if isReady {
            Label("Language model ready", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.success)
        } else if checking {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking language model…").font(.system(size: 13)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity)
            .layoutProbe("model.checking")
        } else {
            switch model.download {
            case .idle:
                ThemeButton("Download model", systemImage: "arrow.down.circle", role: .primary, fullWidth: true) {
                    model.fetchModel()
                }
                .layoutProbe("model.primary")
            case .cancelled:
                ThemeButton("Resume download", systemImage: "arrow.down.circle", role: .primary, fullWidth: true) {
                    model.fetchModel()
                }
            case .running, .retrying:
                DownloadProgressBar(ease: model.ease, height: 6).frame(maxWidth: .infinity)
            case .failed:
                ThemeButton("Try again", role: .secondary, fullWidth: true) { model.fetchModel() }
            case .done:
                EmptyView()
            }
        }
    }

    private var modelCaption: String {
        if isReady { return "" }
        switch model.download {
        case .idle: return checking ? "" : "470 MB, once. It is the only thing the app downloads."
        case .running:
            let (done, total) = model.downloadedBytes
            return total > 0 ? "\(done / 1_000_000) of \(total / 1_000_000) MB" : "Downloading…"
        case .retrying(let attempt, let max): return "Retrying (\(attempt) of \(max))…"
        case .failed(let message, _): return message
        case .cancelled(let done, let total): return pausedCaption(done: done, total: total)
        case .done: return ""
        }
    }
}

/// The welcome page: one fixed size. The language model, then the folders, then the footer; the folder list is the
/// flexible area and scrolls after three rows. Equal top and bottom padding.
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    var onFinish: () -> Void
    var onLater: () -> Void

    static let width: CGFloat = 380
    /// The height follows the content: a short state is short, and the window grows (animated) when folders need room.
    static let slot: CGFloat = 38          // a button, a progress bar and a ready line all fit this one slot
    static let captionHeight: CGFloat = 16
    /// The folder list's area: no room while there are no folders, then one row per folder, up to three; more scroll.
    static func listHeight(rows: Int) -> CGFloat { rows == 0 ? 0 : CGFloat(min(rows, 3)) * 60 }
    static let subtitleHeight: CGFloat = 34

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 12)
            LanguageModelBlock(model: model)
            Hairline().padding(.vertical, 14)
            folderRow
            Spacer(minLength: 12)
            footer
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 24)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)   // the page's ideal height: its spacers take their minimum, not the window
        // the window's glass is WindowGlass (installed with the window), not a SwiftUI background
    }

    private var header: some View {
        VStack(spacing: 8) {
            AppLogoView()
            Text(model.hasFolder ? "You're ready to search" : "Welcome to Semantic Spotlight")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Group {
                if model.hasFolder {
                    Text("Press ⌥ Space anywhere, describe what you remember, press Return.")
                } else {
                    Text("Search your files by meaning. Everything stays on this Mac.")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.muted)
            .multilineTextAlignment(.center)
            .frame(height: Self.subtitleHeight, alignment: .top)
        }
    }

    // Row 2: the folders. While a folder indexes, its own row shows the progress (once); the list is below.
    private var folderRow: some View {
        let indexing = model.rows.contains { $0.tone == .busy }
        return VStack(spacing: 6) {
            Text("Folders to index").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
            Group {
                if indexing {
                    Text("Indexing a folder. Its progress is in the list.")
                        .font(.system(size: 12)).foregroundStyle(Theme.muted)
                } else if model.rows.isEmpty {
                    ThemeButton("Choose folder…", systemImage: "folder", role: .secondary, fullWidth: true) {
                        model.chooseFolder()
                    }
                    .disabled(!model.canChooseFolder)
                } else {
                    ThemeButton("Add another folder", systemImage: "plus", role: .tertiary, size: .compact) {
                        model.chooseFolder()
                    }
                    .disabled(!model.canChooseFolder)
                }
            }
            .frame(maxWidth: .infinity, minHeight: Self.slot, maxHeight: Self.slot)
            // The hint sits right under the button, in the same centred 12 pt style as the other captions.
            Text(model.canChooseFolder ? " " : "Download the language model first.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .frame(height: Self.captionHeight)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        FolderRowView(row: row, count: model.folderCounts[row.path] ?? "", indexLine: model.indexLine)
                        Hairline()
                    }
                }
            }
            .frame(height: Self.listHeight(rows: model.rows.count))
        }
    }

    // The footer: Later until one folder is indexed; then Start searching.
    private var footer: some View {
        Group {
            if model.rows.contains(where: { $0.tone == .ok }) {
                ThemeButton("Start searching", role: .primary, fullWidth: true) { onFinish() }
                    .disabled(!model.canFinish)
            } else {
                ThemeButton("Later", role: .quiet, size: .compact) { onLater() }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.slot, maxHeight: Self.slot)
    }
}

/// The fixed slot for progress text: wide enough for "999 of 999 MB" and "Indexing 999 of 999 files" at 12 pt.
enum ProgressSlot {
    static let width: CGFloat = 260
}

/// A slim progress bar: a 6 pt capsule, the accent fill over the hairline track. Fraction nil is indeterminate (a short
/// fixed-width segment, for a row whose total is not known).
struct SlimProgressBar: View {
    var fraction: Double?
    var fraction0: Double { fraction ?? 0.3 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.edge)
                if fraction0 > 0 {   // nothing done yet (a waiting folder) shows the empty track, not a sliver
                    Capsule().fill(Theme.accent)
                        .frame(width: max(6, geo.size.width * min(fraction0, 1)))
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((fraction0 * 100).rounded())) percent")
    }
}

/// The iCloud wait line, shared by the Settings Folders tab and the menu.
enum CloudWaitLine {
    static func text(_ count: Int) -> String {
        "\(count) \(count == 1 ? "file is" : "files are") in iCloud and \(count == 1 ? "is" : "are") being downloaded"
    }
}

/// One folder of the indexed state: a green check when indexed, a slim bar while indexing, its name and its count, and
/// the failure actions (Retry, Show details) when it was not added. Remove is a small text button, shown on hover.
/// One folder, on one line: the status icon, the name, the path (middle-truncated, it takes the free width), the file count
/// or the indexing count on the right, and Remove on hover at the far right (its slot is always reserved, so the count
/// never moves). While indexing, a slim bar sits under the row. The full path is in the tooltip.
struct FolderRowView: View {
    let row: FolderRow
    /// The folder's file count ("6 files"), shown when the folder is indexed.
    var count = ""
    /// "15 of 309" while the engine counts a run; empty otherwise.
    var indexLine = ""
    /// This folder's own progress in the run (Settings only): its count and bar. Nil keeps the run-wide line.
    var own: FolderProgress? = nil
    @State private var showDetails = false
    @State private var reveal = RevealMachine()
    @State private var revealed = false
    @State private var removeFocused = false   // the keyboard reveals it too: Tab onto Remove
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var shown: Bool { revealed || removeFocused }

    /// The right side: the run's count while indexing (or the step's text when there is no count), the file count when
    /// indexed. A warning or an error says its text under the row instead.
    private var trailing: String {
        switch tone {
        case .busy:
            if let own {   // a waiting folder says so; an indexing one shows its own count
                if own.phase == "waiting" { return "Waiting" }
                return own.total > 0 ? "\(own.done) of \(own.total)" : row.text
            }
            return indexLine.isEmpty ? row.text : indexLine
        case .ok: return count
        case .warning, .error: return ""
        }
    }

    /// The row's tone: with its own progress, a folder is busy until it is done (a warning or an error stays as it is).
    private var tone: FolderRow.Tone {
        guard let own, row.tone != .warning, row.tone != .error else { return row.tone }
        return own.phase == "done" ? .ok : .busy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                icon.frame(width: 16, height: 16)
                Text((row.path as NSString).lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)   // the name is never truncated; the path gives way
                Text((row.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                Text(trailing)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                // The Remove slot is always reserved: revealing it never moves the name or the count.
                ThemeButton("Remove", role: .tertiary, size: .compact, focusChanged: { removeFocused = $0 }) {
                    FolderTracker.shared.remove(row.path)
                }
                .opacity(shown ? 1 : 0)
                .offset(x: shown ? 0 : 6)
                .allowsHitTesting(shown)
                .animation(reduceMotion ? nil : .easeOut(duration: shown ? 0.15 : 0.12), value: shown)
            }
            if tone == .busy {   // only while indexing or adding: a slim bar under the row (indeterminate without a count)
                SlimProgressBar(fraction: own?.fraction).frame(height: 4).padding(.leading, 24)
            }
            if row.tone == .warning || row.tone == .error {
                Text(row.text)
                    .font(.system(size: 12))
                    .foregroundStyle(row.tone == .error ? Theme.danger : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
            if row.retry {
                ThemeButton("Retry", role: .secondary, size: .compact) { FolderTracker.shared.retry(row.path) }
                    .padding(.leading, 24)
            }
            if row.detail != nil {
                ThemeButton(showDetails ? "Hide details" : "Show details", role: .tertiary, size: .compact) {
                    showDetails.toggle()
                }
                .padding(.leading, 24)
                if showDetails, let detail = row.detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                        .textSelection(.enabled)
                        .padding(.leading, 24)
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .help(row.path)
        .onHover { inside in
            if inside { reveal.enter() } else { reveal.exit(now: Date().timeIntervalSinceReferenceDate) }
            revealed = reveal.visible
            if !inside {   // the hysteresis window ends after the pointer has left: then the Remove slot hides
                DispatchQueue.main.asyncAfter(deadline: .now() + RevealMachine.exitDelay + 0.01) {
                    revealed = reveal.isVisible(at: Date().timeIntervalSinceReferenceDate)
                }
            }
        }
    }

    /// The status: a green check when indexed; amber while indexing (a spinner, or a static half circle with Reduce
    /// Motion); amber for a warning; red for an error.
    @ViewBuilder private var icon: some View {
        switch tone {
        case .busy:
            if reduceMotion {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(Theme.warning)
            } else {
                AmberSpinner()
            }
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        case .error: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.danger)
        }
    }
}

/// An amber arc that turns: the indexing spinner (ProgressView ignores a tint on macOS, so it is drawn here).
struct AmberSpinner: View {
    @State private var turning = false

    var body: some View {
        Circle()
            .trim(from: 0.12, to: 1)
            .stroke(Theme.warning, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .frame(width: 14, height: 14)
            .onAppear { withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { turning = true } }
    }
}

/// Owns the welcome window. The model is kept alive so state survives closing the window.
final class OnboardingWindow {
    static let shared = OnboardingWindow()

    let model = OnboardingModel()
    private var window: NSWindow?
    private var host: NSHostingController<OnboardingView>?
    private var refit: AnyCancellable?


    /// The window's height is the page's ideal height at its width; the top edge stays where it is. A change animates in
    /// about 0.2 s (at once with Reduce Motion or when not animated).
    func fitToContent(animated: Bool) {
        guard let target = contentTargetFrame() else { return }
        WindowMotion.animate(window!, to: target, animated: animated)
    }

    /// The frame the window should have for the page as it is now (top edge kept).
    func contentTargetFrame() -> NSRect? {
        guard let window, let host else { return nil }
        let h = host.sizeThatFits(in: CGSize(width: OnboardingView.width, height: CGFloat.greatestFiniteMagnitude)).height
        let size = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: OnboardingView.width, height: h)).size
        return WindowMotion.topAnchored(window.frame, height: size.height)
    }

#if DEBUG
    /// Test only: the window's frame view (the titlebar and the content), for the window-look render.
    var testFrameView: NSView? { window?.contentView?.superview }
    /// Test only: set by testSetState so that the status poll does not overwrite the state being shown.
    var testFrozen = false
    /// Test only: the model behind the window (for the progress test).
    var testModel: OnboardingModel { model }
    /// Test only: the welcome state 1 to 4, as the model would be in the app (for the real-window captures).
    func testSetState(_ n: Int, variant: String = "") {
        testFrozen = true
        model.download = .idle
        model.ease.seed(done: 0, total: 0)
        model.downloadedBytes = (0, 0)
        model.apply(EngineStatus(["files": 0, "chunks": 0, "folders": [], "indexing": false, "model": "m",
                                  "model_ready": n >= 3, "folder_stats": []]), rows: [])
        if n == 2 && variant == "cancelled" {   // a download the user cancelled: "Resume download" and the bytes on disk
            model.download = .cancelled(done: 212_000_000, total: 470_000_000)
            model.downloadedBytes = (212_000_000, 470_000_000)
            model.ease.seed(done: 212_000_000, total: 470_000_000)
        }
        if n == 2 && variant != "cancelled" {
            model.download = .running; model.downloadedBytes = (212_000_000, 470_000_000)
            model.ease.seed(done: 212_000_000, total: 470_000_000)
            if variant == "retrying" { model.download = .retrying(attempt: 2, max: 5) }
            if variant == "error" {
                model.download = .failed(message: "The download stopped. Check the connection and try again.",
                                         detail: "URLError -1009: The Internet connection appears to be offline.\nstep: fetch model.safetensors\nattempts: 5")
            }
        }
        if n == 4 {
            model.apply(EngineStatus(["files": 6, "chunks": 20, "folders": ["/fixture/notes"], "indexing": false, "model": "m",
                                      "model_ready": true, "folder_stats": [["path": "/fixture/notes", "files": 6]]]),
                        rows: [FolderRow(id: "/fixture/notes", path: "/fixture/notes", text: "6 files", tone: .ok)])
            if variant == "indexing" {   // a folder being indexed: the button's footprint shows its progress
                model.apply(EngineStatus(["files": 15, "chunks": 20, "folders": ["/fixture/notes"], "indexing": true, "model": "m",
                                          "model_ready": true, "folder_stats": [["path": "/fixture/notes", "files": 15]]]),
                            rows: [FolderRow(id: "/fixture/notes", path: "/fixture/notes", text: "Indexing 15 of 309 files", tone: .busy)])
            }
            if variant == "mixed" {   // three folders: two indexed, one being indexed
                let paths = ["/fixture/notes", "/fixture/projects", "/fixture/archive"]
                model.apply(EngineStatus(["files": 30, "chunks": 90, "folders": paths, "indexing": true, "model": "m",
                                          "model_ready": true, "folder_stats": paths.map { ["path": $0, "files": 10] },
                                          "progress": ["phase": "indexing", "done": 15, "total": 309]]),
                            rows: [FolderRow(id: paths[0], path: paths[0], text: "10 files", tone: .ok),
                                   FolderRow(id: paths[1], path: paths[1], text: "Indexing 15 of 309 files", tone: .busy),
                                   FolderRow(id: paths[2], path: paths[2], text: "10 files", tone: .ok)])
            }
            if variant == "per-folder" {   // three folders with their own progress: done, 60% and 33%, one not started yet
                let paths = ["/fixture/notes", "/fixture/projects", "/fixture/archive"]
                let own: [[String: Any]] = [["path": paths[0], "phase": "done", "done": 300, "total": 300],
                                            ["path": paths[1], "phase": "indexing", "done": 40, "total": 120]]
                model.apply(EngineStatus(["files": 240, "chunks": 900, "folders": paths, "indexing": true, "model": "m",
                                          "model_ready": true, "waiting_cloud": 4,
                                          "folder_stats": [["path": paths[0], "files": 300], ["path": paths[1], "files": 40]],
                                          "progress": ["phase": "indexing", "done": 340, "total": 420, "folders": own]]),
                            rows: [FolderRow(id: paths[0], path: paths[0], text: "Indexing…", tone: .busy),
                                   FolderRow(id: paths[1], path: paths[1], text: "Indexing…", tone: .busy),
                                   FolderRow(id: paths[2], path: paths[2], text: "Indexing…", tone: .busy)])
            }
            if variant == "three" {   // three folders, all indexed
                let paths = ["/fixture/notes", "/fixture/projects", "/fixture/archive"]
                model.apply(EngineStatus(["files": 30, "chunks": 90, "folders": paths, "indexing": false, "model": "m",
                                          "model_ready": true, "folder_stats": paths.map { ["path": $0, "files": 10] }]),
                            rows: paths.map { FolderRow(id: $0, path: $0, text: "10 files", tone: .ok) })
            }
        }
    }
#endif

    func update(_ status: EngineStatus?, rows: [FolderRow]) {
#if DEBUG
        if testFrozen { return }   // a test has set the page's state; the live status poll must not overwrite it
#endif
        model.apply(status, rows: rows)
        if let window, let host { fitWindow(window, host) }
    }

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView(
                model: model,
                onFinish: { [weak self] in
                    OnboardingState.completed = true
                    self?.window?.close()
                },
                onLater: { [weak self] in self?.window?.close() }))
            let w = AppWindow(contentViewController: host)
            w.styleMask = [.titled, .closable]
            unifiedWindow(w)
            fitWindow(w, host)
            self.host = host
            // The window refits when the state changes (a download event changes the content too, not only the status).
            // The window follows the page's content height (animated); the width and the top edge never change.
            refit = model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
                DispatchQueue.main.async { self?.fitToContent(animated: true) }
            }
            fitToContent(animated: false)
            w.title = "Semantic Spotlight"
            w.isReleasedWhenClosed = false
            w.center()
            // Fast status polling only while this window is visible.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                   object: w, queue: .main) { _ in
                EngineManager.shared.setFastPolling(false)
            }
            window = w
            if Headless.enabled, let w = window { Headless.hide(w) }
        }
        EngineManager.shared.setFastPolling(true)
        if !Headless.enabled { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
        clearInitialFocus(window)
        Headless.hideAllSoon()
    }
}

/// Whether a row's Remove slot is shown. Entering shows it at once. Leaving hides it only after `exitDelay`, so moving
/// across the row (between its parts) does not flicker. Time is passed in, so the state machine is tested with a clock.
struct RevealMachine: Equatable {
    static let exitDelay: TimeInterval = 0.12
    private(set) var visible = false
    private var exitedAt: TimeInterval?

    mutating func enter() {
        visible = true
        exitedAt = nil
    }

    mutating func exit(now: TimeInterval) {
        if exitedAt == nil { exitedAt = now }
    }

    /// Shown now: entered, or left less than `exitDelay` ago.
    mutating func isVisible(at now: TimeInterval) -> Bool {
        if let left = exitedAt, now - left >= Self.exitDelay {
            visible = false
            exitedAt = nil
        }
        return visible
    }
}
