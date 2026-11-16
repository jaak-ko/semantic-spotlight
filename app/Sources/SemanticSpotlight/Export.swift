import AppKit
import UniformTypeIdentifiers

/// Copy and save for diagnostics and reports. Nothing is written except when the user asks for it:
/// no temp copies, no log files. A saved file is created with mode 0600 and never remembered by the app.
enum Export {
    /// Test hooks, used only when SS_UNINSTALL_HOME is set: SS_TEST_CLIPBOARD_FILE receives copies (the real
    /// pasteboard is left alone) and SS_TEST_SAVE_PATH receives saves (no panel is shown).
    static func copy(_ text: String) {
#if DEBUG
        if Uninstall.testHome != nil, let file = Uninstall.env("SS_TEST_CLIPBOARD_FILE") {
            FileManager.default.createFile(atPath: file, contents: Data(text.utf8))
            return
        }
#endif
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// Shows a save panel on the Desktop and writes `text` only if the user confirms. Returns true if it was written.
    @discardableResult
    static func save(_ text: String, defaultName: String) -> Bool {
#if DEBUG
        if Uninstall.testHome != nil, let path = Uninstall.env("SS_TEST_SAVE_PATH") {
            return write(text, to: URL(fileURLWithPath: path))
        }
#endif
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.plainText]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(text, to: url)
    }

    static func write(_ text: String, to url: URL) -> Bool {
        let ok = FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8),
                                                attributes: [.posixPermissions: 0o600])
        chmod(url.path, 0o600)   // createFile keeps the mode of a file that already existed
        return ok
    }

    static func dayStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
