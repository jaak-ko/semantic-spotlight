import Foundation

/// macOS can hide a status item: its visibility is kept in the app's defaults under this key, and a hidden item
/// stays hidden on the next launch. At start, a hidden item is made visible again. Only this key is touched.
enum StatusVisibility {
    static let key = "NSStatusItem VisibleCC Item-0"

    /// Sets the key to true when it is stored as false. Returns true when it changed the store.
    @discardableResult
    static func ensureVisible(_ defaults: PrefStore) -> Bool {
        guard defaults.object(forKey: key) != nil, defaults.bool(forKey: key) == false else { return false }
        defaults.set(true, forKey: key)
        return true
    }
}
