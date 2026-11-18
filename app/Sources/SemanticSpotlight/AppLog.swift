import Foundation

/// The app's own log, app-daemon.log: the engine's stderr with a local timestamp on each line, and the app's own lines
/// (each start of the engine and why, each exit and its code or signal). It is kept across starts. It rotates at 512 KB
/// and keeps four files (the log and .1 to .3), all 0600 in the 0700 folder. The app writes no paths, names or queries.
enum AppLog {
    static let limit = 512 * 1024
    static let files = 4

    private static let queue = DispatchQueue(label: "semsearch.applog")   // every write and rotation runs here
    private static var partial = Data()   // queue only: the engine's output after its last newline
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// One of the app's own lines.
    static func app(_ text: String) {
        queue.async { append(text) }
    }

    /// The engine's output, as it arrives: each complete line is written with its time.
    static func engineOutput(_ data: Data) {
        queue.async {
            partial.append(data)
            while let nl = partial.firstIndex(of: 0x0A) {
                let line = String(decoding: partial[partial.startIndex..<nl], as: UTF8.self)
                partial.removeSubrange(partial.startIndex...nl)
                append(line)
            }
        }
    }

    /// The engine's output ended: a last line without a newline is written too.
    static func engineEnded() {
        queue.async {
            guard !partial.isEmpty else { return }
            append(String(decoding: partial, as: UTF8.self))
            partial = Data()
        }
    }

    /// Waits until the lines written so far are on disk (tests).
    static func flush() { queue.sync {} }

    /// queue only
    private static func append(_ text: String) {
        let path = SemPaths.log
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let bytes = Data((stamp.string(from: Date()) + " " + text + "\n").utf8)
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if size + bytes.count > limit { rotate(path) }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        fchmod(fd, 0o600)   // open keeps the mode of a file that already existed
        bytes.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    /// queue only: the log becomes .1, .1 becomes .2, .2 becomes .3, and the oldest is removed.
    private static func rotate(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: "\(path).\(files - 1)")
        for n in stride(from: files - 2, through: 1, by: -1) {
            try? fm.moveItem(atPath: "\(path).\(n)", toPath: "\(path).\(n + 1)")
        }
        try? fm.moveItem(atPath: path, toPath: path + ".1")
    }
}
