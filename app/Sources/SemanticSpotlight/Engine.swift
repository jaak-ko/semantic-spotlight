import Foundation

/// Paths under ~/.semsearch. Home comes from $HOME, as the engine's expanduser does, so both always agree.
enum SemPaths {
    // Test builds take the home from $HOME (tests run in a fake one). Release takes it from the account: an
    // environment variable cannot move the app's data or its uninstall.
    #if DEBUG
    static let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
    #else
    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    #endif
    static let dir = home + "/.semsearch"
    static let socket = dir + "/daemon.sock"
    static let config = dir + "/config.json"
    static let log = dir + "/app-daemon.log"
}

struct EngineStatus {
    let files: Int
    let chunks: Int
    let folders: [String]
    let folderStats: [String: Int]   // `folder_stats`: files per registered folder; empty on older engines
    let indexing: Bool
    let model: String
    let modelReady: Bool
    /// `model_verifying`: an installed model is being checked (offline, by its hashes) before it counts as ready.
    let modelVerifying: Bool
    let phase: String      // "idle", "scanning" or "indexing"
    let done: Int
    let total: Int
    let hasProgress: Bool  // false on older engines: the `indexing` flag is all there is
    /// `progress.folders`: each folder's own count while a run is busy, keyed by path. Empty on engines without it.
    let folderProgress: [String: FolderProgress]
    /// Whether the engine sent `progress.folders` (an older engine did not, and its rows keep the run-wide numbers).
    let hasFolderProgress: Bool
    /// `progress.waiting_cloud`: files in iCloud the engine is waiting to download (run-level); 0 on older engines.
    let waitingCloud: Int

    init(_ r: [String: Any]) {
        files = r["files"] as? Int ?? 0
        chunks = r["chunks"] as? Int ?? 0
        folders = r["folders"] as? [String] ?? []
        let stats = r["folder_stats"] as? [[String: Any]] ?? []
        folderStats = Dictionary(stats.compactMap { d -> (String, Int)? in
            guard let path = d["path"] as? String, let files = d["files"] as? Int else { return nil }
            return (path, files)
        }, uniquingKeysWith: { first, _ in first })
        indexing = r["indexing"] as? Bool ?? false
        model = r["model"] as? String ?? "-"
        modelReady = r["model_ready"] as? Bool ?? false   // missing key (older engine) counts as not ready
        modelVerifying = r["model_verifying"] as? Bool ?? false   // missing key (older engine): not verifying
        let progress = r["progress"] as? [String: Any]     // {"phase", "done", "total"}: counts only, no names
        hasProgress = progress != nil
        phase = progress?["phase"] as? String ?? (indexing ? "indexing" : "idle")
        done = progress?["done"] as? Int ?? 0
        total = progress?["total"] as? Int ?? 0
        let perFolder = progress?["folders"] as? [[String: Any]]
        hasFolderProgress = perFolder != nil
        folderProgress = Dictionary((perFolder ?? []).compactMap { d -> (String, FolderProgress)? in
            guard let path = d["path"] as? String else { return nil }
            return (path, FolderProgress(path: path, phase: d["phase"] as? String ?? "indexing",
                                         done: d["done"] as? Int ?? 0, total: d["total"] as? Int ?? 0))
        }, uniquingKeysWith: { first, _ in first })
        waitingCloud = progress?["waiting_cloud"] as? Int ?? 0
    }

    /// Each folder's own progress for the Folders tab while a run is busy. A folder the engine has not reached yet is
    /// "waiting". Empty when the engine sent no per-folder progress, or when nothing is running.
    var ownFolderProgress: [String: FolderProgress] {
        guard hasFolderProgress, busy else { return [:] }
        var out: [String: FolderProgress] = [:]
        for path in folders {
            out[path] = folderProgress[path] ?? FolderProgress(path: path, phase: "waiting", done: 0, total: 0)
        }
        return out
    }

    /// Work is going on: scanning or indexing (or, on an older engine, its `indexing` flag is set).
    var busy: Bool { phase != "idle" || indexing }

    /// A bar with a known fraction: only while indexing with a known total.
    var determinate: Bool { hasProgress && phase == "indexing" && total > 0 }

    /// The one line both the menu and the welcome window show while busy.
    var progressLine: String {
        if determinate { return "Indexing \(done) of \(total) files" }
        if phase == "scanning" { return "Looking for changes…" }
        return busy ? "Indexing…" : ""
    }
}

/// One folder's progress in a run, from `progress.folders`. Counts only, the path is the key.
struct FolderProgress: Equatable {
    let path: String
    let phase: String    // "waiting" (not started), "indexing" or "done"
    let done: Int
    let total: Int

    /// The bar's fraction: empty while waiting, done/total while indexing, nil when the total is not known.
    var fraction: Double? {
        if phase == "waiting" { return 0 }
        guard total > 0 else { return nil }
        return min(max(Double(done) / Double(total), 0), 1)
    }
}

struct Hit: Identifiable {
    let id: String
    let path: String
    let score: Double          // rank score from the engine; not a relevance measure
    let similarity: Double?    // raw cosine of the best chunk; nil on engines that don't send it
    let snippet: String
}

enum EngineError: LocalizedError {
    case unreachable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unreachable: return "Engine not running yet. Starting it…"
        case .failed(let message): return message
        }
    }
}

/// One request per connection: newline-delimited JSON over ~/.semsearch/daemon.sock.
/// Blocking calls; never call from the main thread.
// Stateless apart from the socket path, so safe to share across threads.
final class EngineClient: @unchecked Sendable {
    let socketPath = SemPaths.socket

    func request(_ body: [String: Any], timeout: Int = 30) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EngineError.failed("socket() failed") }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        let tvLen = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, tvLen)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, tvLen)

        var addr = sockaddr_un()
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw EngineError.failed("socket path too long")
        }
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = UInt8(bitPattern: b) }
        }
        let rc = withUnsafePointer(to: addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw EngineError.unreachable }

        var out = try JSONSerialization.data(withJSONObject: body)
        out.append(0x0A)
        var sent = 0
        try out.withUnsafeBytes { buf in
            while sent < buf.count {
                let n = write(fd, buf.baseAddress! + sent, buf.count - sent)
                guard n > 0 else { throw EngineError.failed("write to engine failed") }
                sent += n
            }
        }

        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !reply.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw EngineError.failed("engine closed the connection or timed out") }
            reply.append(contentsOf: chunk[0..<n])
        }
        let line = Data(reply.prefix(while: { $0 != 0x0A }))
        guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw EngineError.failed("bad reply from engine")
        }
        if (obj["ok"] as? Bool) == false {
            throw EngineError.failed(obj["error"] as? String ?? "unknown engine error")
        }
        return obj
    }
}

/// Owns the connection to the daemon: polls status, starts the daemon as a child
/// process when it is not reachable, restarts it if it dies, and stops it on quit.
final class EngineManager: FolderEngine {
    static let shared = EngineManager()

    /// Called on the main thread with the latest status (nil when not running) and a status line.
    var onChange: ((EngineStatus?, String) -> Void)?

    private let client = EngineClient()
    private let queue = DispatchQueue(label: "semsearch.status")   // status + child process
    private let jobs = DispatchQueue(label: "semsearch.jobs")      // index/add/remove/query-style work
    private var child: Process?
    private var indexOnUp = true            // queue only: send `index` when a daemon answers (launch, and after each restart)
    private var lastStatusAt: TimeInterval = -.infinity   // queue only: status polls are at least 0.5 s apart
    static let minStatusGap: TimeInterval = 0.5
    private var quitting = false
    private var nextPoll: DispatchWorkItem?  // queue only: the one pending poll
    private var lastBusy = false             // queue only
    private var wantFastPolling = false      // queue only; set by the welcome window
    private var nextStart: String?           // queue only: why the next start happens (nil: the first launch)

    /// The engine executable. Order: the runtime bundled in the app; for development, the checkout named by
    /// SS_ENGINE_PATH (environment only: nothing is written to the user's home); then a parent of the app bundle.
    static func engineBinary() -> String? {
        let fm = FileManager.default
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("runtime/bin/semsearch").path,
           fm.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let devBin = { (root: String) in root + "/.venv/bin/semsearch" }
        if let root = ProcessInfo.processInfo.environment["SS_ENGINE_PATH"], fm.isExecutableFile(atPath: devBin(root)) {
            return devBin(root)
        }
        var url = Bundle.main.bundleURL
        for _ in 0..<8 {
            url = url.deletingLastPathComponent()
            if fm.isExecutableFile(atPath: devBin(url.path)) { return devBin(url.path) }
        }
        return nil
    }

    /// Stops the daemon we started so the supervisor relaunches it (e.g. after a model download).
    func restartEngine() {
        queue.async {
            self.nextStart = "model ready"
            if let c = self.child, c.isRunning { c.terminate() }
        }
    }

    /// Polls status: every 0.5 s while the engine is busy, 1 s while the welcome window is open, 5 s otherwise.
    /// No timer runs between polls: each poll schedules the next one.
    func start() {
        queue.async { self.tick() }
    }

    /// Polls at once, and at the faster rate while the welcome window is open.
    func setFastPolling(_ on: Bool) {
        queue.async {
            self.wantFastPolling = on
            self.tick()
        }
    }

    /// Runs requests in order off the main thread, then refreshes status.
    func send(_ requests: [[String: Any]]) {
        jobs.async {
            for r in requests {
                do {
                    _ = try self.client.request(r, timeout: 600)
                } catch {
                    NSLog("Semantic Spotlight: %@", error.localizedDescription)
                }
            }
            self.queue.async { self.tick() }
        }
    }

    /// Registers a folder and reports the engine's answer (nil on success, else the error text).
    /// The completion runs on the main thread.
    func addFolder(_ path: String, completion: @escaping (AddProblem?) -> Void) {
        jobs.async {
            var problem: AddProblem?
            do {
                _ = try self.client.request(["cmd": "add", "path": path], timeout: 600)
            } catch {
                problem = AddProblem.from(error)
            }
            DispatchQueue.main.async { completion(problem) }
            self.queue.async { self.tick() }
        }
    }

    /// Whether the engine answers `ping` now. Runs on its own queue, so a long add never delays it.
    func ping(_ completion: @escaping (Bool) -> Void) {
        let client = self.client
        DispatchQueue.global(qos: .userInitiated).async {
            let up = (try? client.request(["cmd": "ping"], timeout: 2)) != nil
            DispatchQueue.main.async { completion(up) }
        }
    }

    /// Starts the engine if it is not running (the supervisor's path: the next poll starts the child).
    func startEngine() {
        start()
    }

    func removeFolder(_ path: String) {
        send([["cmd": "remove", "path": path]])
    }

    /// The query request. `folders` is left out when nil (every folder), so engines without the scope still work.
    static func queryRequest(_ text: String, limit: Int, folders: [String]?) -> [String: Any] {
        var request: [String: Any] = ["cmd": "query", "q": text, "n": limit]
        if let folders { request["folders"] = folders }
        return request
    }

    /// Top-N semantic matches for `text`, within `folders` when given. Runs off the main thread.
    func query(_ text: String, limit: Int, folders: [String]? = nil) async -> Result<[Hit], Error> {
        let client = self.client
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                do {
                    let r = try client.request(Self.queryRequest(text, limit: limit, folders: folders), timeout: 20)
                    let rows = r["results"] as? [[String: Any]] ?? []
                    let hits = rows.enumerated().map { i, d in
                        Hit(id: "\(i)",
                            path: d["path"] as? String ?? "",
                            score: (d["score"] as? NSNumber)?.doubleValue ?? 0,
                            similarity: (d["similarity"] as? NSNumber)?.doubleValue,
                            snippet: d["snippet"] as? String ?? "")
                    }
                    cont.resume(returning: .success(hits))
                } catch {
                    cont.resume(returning: .failure(error))
                }
            }
        }
    }

    /// Stops the daemon if we started it (SIGTERM). A daemon started elsewhere is left alone.
    func shutdown() {
        quitting = true
        guard let c = child, c.isRunning else { return }
        c.terminate()
        let deadline = Date().addingTimeInterval(3)
        while c.isRunning && Date() < deadline { usleep(50_000) }
        if c.isRunning { kill(c.processIdentifier, SIGKILL) }
    }

    // MARK: - private (queue only)

    private func tick() {
        // send() and the welcome window ask for a poll at once; they wait here so status is never asked for faster than 0.5 s.
        let wait = Self.minStatusGap - (Date().timeIntervalSinceReferenceDate - lastStatusAt)
        if wait > 0 { scheduleNext(after: wait); return }
        lastStatusAt = Date().timeIntervalSinceReferenceDate
        do {
            let status = EngineStatus(try client.request(["cmd": "status"], timeout: 5))
            lastBusy = status.busy
            if indexOnUp {   // the run continues where the last one stopped (a memory restart keeps what was committed)
                indexOnUp = false
                send([["cmd": "index"]])
            }
            publish(status, "Running")
        } catch {
            lastBusy = false
            publish(nil, startChild())
        }
        scheduleNext()
    }

    /// Replaces any pending poll, so polls never multiply.
    private func scheduleNext(after delay: TimeInterval? = nil) {
        nextPoll?.cancel()
        let interval: TimeInterval = delay ?? (lastBusy ? Self.minStatusGap : (wantFastPolling ? 1 : 5))
        let work = DispatchWorkItem { [weak self] in self?.tick() }
        nextPoll = work
        queue.asyncAfter(deadline: .now() + interval, execute: work)
    }

    private func startChild() -> String {
        if quitting { return "Stopped" }
        if let c = child, c.isRunning { return "Starting engine…" }
        guard let bin = Self.engineBinary() else {
            return "Engine not found. Reinstall the app."
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["daemon"]
        p.currentDirectoryURL = URL(fileURLWithPath: bin).deletingLastPathComponent()
        p.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()   // the engine's stderr goes to the app's log, with a time on each line
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                AppLog.engineEnded()
            } else {
                AppLog.engineOutput(data)
            }
        }
        p.terminationHandler = { [weak self] proc in
            let how = proc.terminationReason == .uncaughtSignal ? "signal \(proc.terminationStatus)" : "exit code \(proc.terminationStatus)"
            self?.queue.async {
                AppLog.app("app: engine exited (\(how))")
                if self?.nextStart == nil { self?.nextStart = "restart after \(how)" }
            }
        }
        do {
            try p.run()
            child = p
            indexOnUp = true
            AppLog.app("app: starting engine (reason: \(nextStart ?? "launch"))")
            nextStart = nil
            return "Starting engine…"
        } catch {
            return "Engine failed to start: \(error.localizedDescription)"
        }
    }

    private func publish(_ status: EngineStatus?, _ message: String) {
        DispatchQueue.main.async { self.onChange?(status, message) }
    }
}
