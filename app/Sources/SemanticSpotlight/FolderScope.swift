import Foundation

/// The few preference calls the search makes. The app uses UserDefaults; tests use MemoryPrefs, so a test run never
/// writes the user's preferences (UserDefaults keeps its files in the real home, whatever HOME says).
protocol PrefStore: AnyObject {
    func object(forKey key: String) -> Any?
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func stringArray(forKey key: String) -> [String]?
    func dictionary(forKey key: String) -> [String: Any]?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PrefStore {}

#if DEBUG
final class MemoryPrefs: PrefStore {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}
#endif

/// The preference store for this run: the defaults, or a memory store in test runs.
enum AppPrefs {
    #if DEBUG
    static let testStore = MemoryPrefs()
    static var store: PrefStore { Uninstall.testHome != nil ? testStore : UserDefaults.standard }
    #else
    static var store: PrefStore { UserDefaults.standard }
    #endif
}

/// Which indexed folders a search uses. The defaults store the EXCLUDED folders, so a folder added later is included
/// by default, and a removed folder drops out of the stored list. The key lives in the app's own defaults domain, so
/// the uninstall removes it with the preferences file. Main thread only.
final class FolderScope: ObservableObject {
    static let excludedKey = "searchExcludedFolders"

    /// The engine's registered folders, in the engine's order, and their file counts (`folder_stats`).
    @Published private(set) var registered: [String] = []
    @Published private(set) var fileCounts: [String: Int] = [:]
    @Published private(set) var excluded: Set<String>

    private let defaults: PrefStore

    init(defaults: PrefStore = AppPrefs.store) {
        self.defaults = defaults
        excluded = Set(defaults.stringArray(forKey: Self.excludedKey) ?? [])
    }

    /// Takes the engine's folder list. Folders the engine no longer has drop out of the stored exclusions. A nil status
    /// (the engine is down) changes nothing, so the choice survives a restart with the engine off.
    func reconcile(_ status: EngineStatus?) {
        guard let status else { return }
        registered = status.folders
        fileCounts = status.folderStats
        let kept = excluded.intersection(status.folders)
        if kept != excluded {
            excluded = kept
            save()
        }
    }

    /// The included folders, in the engine's order.
    var included: [String] { registered.filter { !excluded.contains($0) } }

    func isIncluded(_ path: String) -> Bool { !excluded.contains(path) }

    func toggle(_ path: String) {
        guard registered.contains(path) else { return }
        if excluded.contains(path) { excluded.remove(path) } else { excluded.insert(path) }
        save()
    }

    func setAll(included all: Bool) {
        excluded = all ? [] : Set(registered)
        save()
    }

    /// Every registered folder is included (or there are none): nothing narrows the search.
    var allIncluded: Bool { excluded.isDisjoint(with: registered) }

    /// Folders exist, and none is included: the search has nothing to look in.
    var noneIncluded: Bool { !registered.isEmpty && included.isEmpty }

    /// Some folder is left out: the scope is narrowed.
    var narrowed: Bool { !registered.isEmpty && !allIncluded }

    /// The `folders` value of a query. Nil when every folder is included, so the key is left out of the request
    /// (older engines search everything, as before). Otherwise the included folders, possibly none.
    var requestFolders: [String]? {
        if registered.isEmpty || allIncluded { return nil }
        return included
    }

    /// Files under a folder, from `folder_stats`; nil when the engine did not send it.
    func fileCount(_ path: String) -> Int? { fileCounts[path] }

    /// The scope chip's count: "2/3" (included over registered).
    var badge: String { "\(included.count)/\(registered.count)" }

    var accessibilityLabel: String {
        if registered.isEmpty { return "No folders indexed" }
        if noneIncluded { return "No folders selected" }
        if allIncluded { return "Searching all \(registered.count) folders" }
        return "Searching \(included.count) of \(registered.count) folders"
    }

    private func save() {
        defaults.set(excluded.sorted(), forKey: Self.excludedKey)
    }
}
