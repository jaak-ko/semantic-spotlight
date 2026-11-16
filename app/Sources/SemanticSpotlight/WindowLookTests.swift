#if DEBUG
import AppKit

/// Test only (run by the theme test): the real windows of the redesign, rendered from their frame views, so the
/// titlebar and the content are both in the picture. The frame view is AppKit's window chrome around the content.
enum WindowLookTests {
    static func render(dir: String) {
        SettingsWindow.shared.show()
        OnboardingWindow.shared.show()
        for dark in [false, true] {
            for (name, view) in [("settings", SettingsWindow.shared.testFrameView), ("welcome", OnboardingWindow.shared.testFrameView)] {
                guard let view else { continue }
                view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                view.layoutSubtreeIfNeeded()
                _ = UIDumpFormat.png(view, to: "\(dir)/window-\(name)-\(dark ? "dark" : "light").png")
            }
        }
    }
}
#endif
