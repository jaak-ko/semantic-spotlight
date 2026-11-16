import AppKit

/// The menu-bar icon: a plain magnifying glass, a template image that follows the menu bar's light, dark and tinted
/// appearances. It is static at all times. Indexing shows in the progress row of the menu, not in the icon.
enum MenuBarIcon {
    /// How many times an icon was assigned to a status button. Assigned once per item, at creation: a test checks it.
    #if DEBUG
    private(set) static var assignments = 0
    #endif

    /// The one menu-bar image: a magnifying glass, a template, so macOS tints it for light, dark and tinted bars.
    static func image() -> NSImage {
        let image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Semantic Spotlight") ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// Assigns the icon to a button. Called once, when the status item is created; never on a status change.
    static func install(on button: NSStatusBarButton?) {
        guard let button else { return }
        button.image = image()
        #if DEBUG
        assignments += 1
        #endif
    }

#if DEBUG
    /// Test runs write their check lines to stderr (the test roots are the only way to get here).
    static func testLog(_ line: String) {
        guard Uninstall.testHome != nil else { return }
        FileHandle.standardError.write("[test] \(line)\n".data(using: .utf8)!)
    }
#endif
}
