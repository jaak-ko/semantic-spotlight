import AppKit

/// The one way out of the app, used by every Quit button and the menu item.
/// A sheet still attached to a window makes NSApp.terminate refuse (and beep), so attached sheets are ended first.
/// The engine is stopped here, once; applicationWillTerminate finds it already stopped. A timer exits the process
/// if terminate is still refused, so Quit always works.
enum AppQuit {
    static func now() {
#if DEBUG
        if Uninstall.testHome != nil {   // test only: the moment Quit was pressed, so a test can time the exit
            FileHandle.standardError.write("quit-pressed \(Date().timeIntervalSince1970)\n".data(using: .utf8)!)
        }
#endif
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        EngineManager.shared.shutdown()
        NSApp.terminate(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { exit(0) }
    }
}
