import AppKit

/// Where the search panel sits. The default: centered horizontally, its top edge at about 78% of the visible height of
/// the screen the pointer is on. After the user drags the panel, its origin is remembered per screen, relative to that
/// screen's frame, in the app's defaults (`searchPanelPositions`). A remembered place that no longer fits the screen
/// (a display was removed, or the resolution changed) is ignored, and the default is used.
enum SearchPlacement {
    static let key = "searchPanelPositions"   // [screen id: [dx, dy]]
    /// The height of the top row (the lens, the field and the scope chip).

    /// The display number of a screen, as a stable key; nil if the screen has none.
    static func screenID(_ screen: NSScreen) -> String? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { "\($0.intValue)" }
    }

    static func defaultOrigin(size: NSSize, in visible: NSRect) -> NSPoint {
        let top = visible.minY + visible.height * 0.78
        // Whole points: a window's origin snaps to them, so the placed and the computed origins must agree.
        return NSPoint(x: (visible.midX - size.width / 2).rounded(), y: (top - size.height).rounded())
    }

    /// The remembered origin for `screen`, if it is still on that screen; nil means use the default.
    static func restoredOrigin(size: NSSize, screen: NSScreen, defaults: PrefStore) -> NSPoint? {
        guard let id = screenID(screen),
              let saved = (defaults.dictionary(forKey: key) ?? [:])[id] as? [Double], saved.count == 2 else { return nil }
        let origin = NSPoint(x: screen.frame.minX + saved[0], y: screen.frame.minY + saved[1])
        return screen.visibleFrame.contains(NSRect(origin: origin, size: size)) ? origin : nil
    }

    static func save(origin: NSPoint, screen: NSScreen, defaults: PrefStore) {
        guard let id = screenID(screen) else { return }
        var all = defaults.dictionary(forKey: key) ?? [:]
        all[id] = [Double(origin.x - screen.frame.minX), Double(origin.y - screen.frame.minY)]
        defaults.set(all, forKey: key)
    }

    /// Forgets the remembered place on `screen`, so the next show uses the default there.
    static func clear(screen: NSScreen, defaults: PrefStore) {
        guard let id = screenID(screen) else { return }
        var all = defaults.dictionary(forKey: key) ?? [:]
        all.removeValue(forKey: id)
        defaults.set(all, forKey: key)
    }

    /// The screen that holds most of `rect`, else the one under the pointer, else the main screen.
    static func screen(holding rect: NSRect) -> NSScreen {
        let best = NSScreen.screens.max { a, b in
            a.frame.intersection(rect).width * a.frame.intersection(rect).height <
                b.frame.intersection(rect).width * b.frame.intersection(rect).height
        }
        if let best, best.frame.intersects(rect) { return best }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
}
