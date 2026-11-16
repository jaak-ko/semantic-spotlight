import Foundation

/// What this session did with a folder. Live numbers come from the engine's status poll.
enum FolderPhase {
    case adding
    case waitingForEngine(until: Date)                              // the engine is starting: polled until this time
    case indexing(baseline: Int, since: Date, registered: Bool)   // baseline: total files when the add started
    case done(Int)                 // files gained from this folder
    case noFiles(registered: Bool) // nothing gained; registered = it was already in the index
    case notAdded(AddProblem)      // the add failed; the folder stays listed, with Retry
}

/// One line in the folder list (menu or welcome window). Equatable so UIs only refresh on change.
struct FolderRow: Identifiable, Equatable {
    enum Tone: Equatable { case ok, busy, warning, error }
    let id: String
    let path: String
    let text: String
    let tone: Tone
    /// The engine's technical text, for "Show details" (engine errors only).
    var detail: String? = nil
    /// The folder is listed but not added: Retry is offered.
    var retry: Bool = false
}

/// The engine as the folder tracker needs it. EngineManager is the production one; tests script their own.
protocol FolderEngine: AnyObject {
    /// Whether the engine answers now. Completion on the main queue.
    func ping(_ completion: @escaping (Bool) -> Void)
    /// Registers a folder. Completion on the main queue with nil on success, else why it failed.
    func addFolder(_ path: String, completion: @escaping (AddProblem?) -> Void)
    /// Starts the engine if it is not running (the supervisor's path).
    func startEngine()
    /// Removes a folder from the engine's index.
    func removeFolder(_ path: String)
}

/// Tracks folders added in this session and turns engine status into per-folder rows.
/// The engine reports totals only, so "files" in the text are totals across all folders.
/// Main thread only.
final class FolderTracker {
    static let shared = FolderTracker()

    /// Fired when an add finishes (success or failure) or a folder is removed, so UIs refresh.
    var onChange: (() -> Void)?
    /// The engine used for adds. Tests replace it.
    var engine: FolderEngine = EngineManager.shared
    /// How long an add waits for the engine to come up before it fails, and how often it asks. Tests shorten them.
    var waitBudget: TimeInterval = 15
    var pollInterval: TimeInterval = 0.5

    private var phases: [String: FolderPhase] = [:]
    private var lastFiles = 0
    private var lastFolders: [String] = []
    /// Indexing can start a moment after `add` returns, so a folder settles only after this grace period.
    private let settleDelay: TimeInterval = 2.5

    /// Registers `path` with the engine. If the engine is not up yet, shows "Starting the engine…" and waits for it
    /// (up to `waitBudget`) before it fails. A failure keeps the folder in the list, with Retry.
    func add(_ path: String, onFailure: ((String) -> Void)? = nil) {
        waitThenAdd(path, until: Date().addingTimeInterval(waitBudget))
    }

    /// Retry on a folder that could not be added: starts the engine if it is not running, then adds it again.
    func retry(_ path: String) {
        guard case .notAdded? = phases[path] else { return }
        engine.startEngine()
        waitThenAdd(path, until: Date().addingTimeInterval(waitBudget))
    }

    /// Asks the engine until it answers, then adds the folder. Gives up at `until` with "not running".
    private func waitThenAdd(_ path: String, until: Date) {
        phases[path] = .waitingForEngine(until: until)
        onChange?()
        engine.ping { [weak self] up in
            guard let self, case .waitingForEngine? = self.phases[path] else { return }   // removed meanwhile
            if up {
                self.sendAdd(path)
            } else if Date() < until {
                DispatchQueue.main.asyncAfter(deadline: .now() + self.pollInterval) { [weak self] in
                    guard let self, case .waitingForEngine? = self.phases[path] else { return }
                    self.waitThenAdd(path, until: until)
                }
            } else {
                self.phases[path] = .notAdded(.notRunning)
                self.onChange?()
            }
        }
    }

    private func sendAdd(_ path: String) {
        let baseline = lastFiles
        let registered = lastFolders.contains(path)
        phases[path] = .adding
        onChange?()
        engine.addFolder(path) { [weak self] problem in
            guard let self else { return }
            if let problem {
                if case .notRunning = problem {
                    // The engine went away between the ping and the add: wait for it again.
                    self.waitThenAdd(path, until: Date().addingTimeInterval(self.waitBudget))
                    return
                }
                self.phases[path] = .notAdded(problem)
            } else {
                self.phases[path] = .indexing(baseline: baseline, since: Date(), registered: registered)
            }
            self.onChange?()
        }
    }

    func remove(_ path: String) {
        phases.removeValue(forKey: path)
        engine.removeFolder(path)
        onChange?()
    }

    /// Called on every status poll. Settles folders whose indexing has finished.
    func apply(_ status: EngineStatus?) {
        guard let status else { return }
        lastFiles = status.files
        lastFolders = status.folders
        for (path, phase) in phases {
            guard case .indexing(let baseline, let since, let registered) = phase,
                  !status.busy, Date().timeIntervalSince(since) > settleDelay else { continue }
            let gained = status.files - baseline
            phases[path] = gained > 0 ? .done(gained) : .noFiles(registered: registered)
        }
    }

    /// Every registered folder, plus folders still being added or that could not be added.
    func rows(_ status: EngineStatus?) -> [FolderRow] {
        var paths = status?.folders ?? []
        for path in phases.keys.sorted() where !paths.contains(path) { paths.append(path) }
        return paths.map { path in
            let (text, tone) = describe(path, status)
            var row = FolderRow(id: path, path: path, text: text, tone: tone)
            if case .notAdded(let problem)? = phases[path] {
                row.retry = true
                if case .engine(let technical) = problem { row.detail = technical }
            }
            return row
        }
    }

    private func describe(_ path: String, _ status: EngineStatus?) -> (String, FolderRow.Tone) {
        let busy = status?.busy ?? false
        // Static text on purpose: a row's text is part of the menu's structure, and live counts change on every
        // progress tick. The live counts are shown in the progress row, which changes in place.
        switch phases[path] {
        case .adding?:
            return ("Adding…", .busy)
        case .waitingForEngine?:
            return ("Starting the engine…", .busy)
        case .notAdded(let problem)?:
            return (AddProblem.rowText(problem), .error)
        case .indexing?:
            return busy ? ("Indexing…", .busy) : ("Finishing…", .busy)
        case .done(let count)?:
            return ("Done: \(count) files indexed", .ok)
        case .noFiles(let registered)?:
            return registered
                ? ("Already added. No new supported files found.", .warning)
                : ("No supported files found in this folder", .warning)
        case nil:
            return busy ? ("Indexing…", .busy) : ("Ready", .ok)
        }
    }
}

/// Why a folder could not be added. The folder stays in the list, with Retry, and the text says which cause it was.
enum AddProblem: Equatable {
    case notRunning          // the engine is not running, not started yet, or did not answer in time
    case modelMissing        // the language model is not installed yet
    case engine(String)      // a genuine engine error; its text is the detail

    /// Sorts an error from the engine request into a cause.
    static func from(_ error: Error) -> AddProblem {
        guard let engineError = error as? EngineError else { return .engine(error.localizedDescription) }
        switch engineError {
        case .unreachable:
            return .notRunning
        case .failed(let text):
            // No reply within the timeout: the engine is still loading.
            if text.hasPrefix("engine closed the connection") { return .notRunning }
            let lower = text.lowercased()
            if lower.contains("model") && (lower.contains("fetch-model") || lower.contains("not installed")
                                           || lower.contains("not downloaded")) {
                return .modelMissing
            }
            return .engine(text)
        }
    }

    /// The row's line for each cause. Plain words; the technical text is only in the row's detail.
    static func rowText(_ problem: AddProblem) -> String {
        switch problem {
        case .notRunning: return "Not added yet. The search engine isn't running yet."
        case .modelMissing: return "Not added yet. Download the language model first."
        case .engine: return "Not added yet. The search engine reported an error."
        }
    }
}
