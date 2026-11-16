import Foundation
import CoreServices

/// Watches the registered folders with FSEvents and calls `onChange` once things
/// have been quiet for 5 seconds. Main-thread only.
final class FolderWatcher {
    static let shared = FolderWatcher()

    var onChange: (() -> Void)?

    private var stream: FSEventStreamRef?
    private var folders: [String] = []
    private var pending: DispatchWorkItem?

    func setFolders(_ new: [String]) {
        let expanded = new.map { ($0 as NSString).expandingTildeInPath }.sorted()
        guard expanded != folders else { return }
        folders = expanded
        stop()
        start()
    }

    private func start() {
        guard !folders.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().scheduleIndex()
        }
        guard let s = FSEventStreamCreate(nil, callback, &ctx, folders as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          2.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                                                   | kFSEventStreamCreateFlagNoDefer)) else { return }
        stream = s
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
    }

    private func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func scheduleIndex() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }
}
