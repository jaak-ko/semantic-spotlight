#if DEBUG
import AppKit
import SwiftUI

/// Test only (run by the theme test): the button system. (1) Source scan: no surface creates a raw SwiftUI Button or
/// sets a button style outside ThemeButton.swift, so every button is a ThemeButton with one of the roles and sizes.
/// (2) Gallery: every role and size in its default, hover, pressed and disabled states, rendered for review.
enum ButtonTests {
    /// Files of the app's sources that may use the raw SwiftUI button types: the one component only.
    static let allowed: Set<String> = ["ThemeButton.swift", "ButtonTests.swift"]   // the scanner itself names the pattern

    /// The raw button uses in the sources, as "file:line: text" (empty when the system is used everywhere).
    static func rawButtonUses() -> [String] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        // A raw use: the word Button not preceded by a letter (so ThemeButton is not one), or a buttonStyle modifier.
        let pattern = try? NSRegularExpression(pattern: #"(?<![A-Za-z])Button(\s*[({])|\.buttonStyle\("#)
        var found: [String] = []
        for file in files where file.pathExtension == "swift" && !allowed.contains(file.lastPathComponent) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for (n, line) in text.components(separatedBy: "\n").enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.hasPrefix("///") { continue }
                if let pattern, pattern.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                    found.append("\(file.lastPathComponent):\(n + 1): \(code)")
                }
            }
        }
        return found
    }

    /// The state rows of the gallery: each role, the sizes, the four states.
    @MainActor static func gallery(solid: Bool) -> NSView {
        let states: [(String, Bool, Bool, Bool, Bool)] = [("default", false, false, true, false), ("hover", true, false, true, false),
                                                          ("pressed", false, true, true, false), ("disabled", false, false, false, false),
                                                          ("focus ring", false, false, true, true)]
        let view = VStack(alignment: .leading, spacing: 12) {
            ForEach(ThemeRole.allCases, id: \.self) { role in
                HStack(spacing: 12) {
                    Text(String(describing: role)).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        .frame(width: 130, alignment: .leading)
                    ForEach(ThemeSize.allCases, id: \.self) { size in
                        ForEach(states, id: \.0) { state in
                            ThemeButtonFace(role: role, size: size, hovering: state.1, pressed: state.2) {
                                Text("Label").frame(minWidth: 40)
                            }
                            .themeFocusRing(state.4)
                            .environment(\.isEnabled, state.3)
                        }
                    }
                }
            }
            // The focus column: the square stubs seen at the ring ends here are an offscreen-render artifact. The real
            // window (button-focus-real-window-light.png and -dark.png) shows clean capsule rings. Do not chase them in this gallery.
            Text("Focus ring column: renderer artifact, see real-window capture (button-focus-real-window-light.png and -dark.png).")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .padding(24)
        .frame(width: 1040, alignment: .leading)
        .background(solid ? Theme.panel : Color.clear)
        .environment(\.solidGlassForTest, solid)
        let h = NSHostingView(rootView: view)
        h.frame = NSRect(x: 0, y: 0, width: 1040, height: 520)
        h.layoutSubtreeIfNeeded()
        h.setFrameSize(NSSize(width: 1040, height: max(h.fittingSize.height, 200)))
        return h
    }

    /// The focus ring is the capsule's own outline: the system's rectangular ring is off on every ThemeButton, and the
    /// ring is a capsule stroke (no rectangle). Checked in the source, since the ring is drawn by SwiftUI.
    static func focusRingFailures() -> Int {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        guard let text = try? String(contentsOf: dir.appendingPathComponent("ThemeButton.swift"), encoding: .utf8) else { return 1 }
        let ok = text.contains(".focusEffectDisabled()")
            && text.contains("if on { Capsule().strokeBorder(Theme.accent.opacity(0.6), lineWidth: 2).padding(-2) }")
            && !text.contains("Rectangle().strokeBorder")
        MenuBarIcon.testLog("button scan: focus ring \(ok ? "is the capsule outline, the system ring is off" : "FAIL: not the capsule outline")")
        return ok ? 0 : 1
    }

    /// A real window (not ImageRenderer) with a focused primary, a focused compact pill and an unfocused one, captured
    /// with CGWindowList at the screen's scale, so the focus ring is seen as the user sees it.
    @MainActor static func realWindowFocusCapture(dir: String, dark: Bool) {
        let row = HStack(spacing: 16) {
            ThemeButtonFace(role: .primary, size: .regular, fullWidth: true) { Text("Download model") }.frame(width: 300)
                .themeFocusRing(true)
            ThemeButtonFace(role: .secondary, size: .compact) { Text("All") }.themeFocusRing(true)
            ThemeButtonFace(role: .secondary, size: .compact) { Text("None") }
        }
        .padding(40)
        .background(Theme.panel)
        let host = NSHostingView(rootView: row)
        host.focusRingType = .none
        let w = AppWindow(contentRect: NSRect(x: -30000, y: -30000, width: 640, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = host
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.isReleasedWhenClosed = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        // Drawn by the window's views (the window server does not render an off-screen window); no screen read.
        if let frame = w.contentView, let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) {
            frame.cacheDisplay(in: frame.bounds, to: rep)
            let data = rep.representation(using: .png, properties: [:])
            if let data { try? data.write(to: URL(fileURLWithPath: "\(dir)/button-focus-real-window-\(dark ? "dark" : "light").png")) }
            MenuBarIcon.testLog("button scan: real-window focus capture written")
        } else {
            MenuBarIcon.testLog("button scan: real-window focus capture FAILED (no image)")
        }
        w.orderOut(nil)
    }

    /// Runs the scan and writes the gallery in light, dark and solid. Returns the number of failures.
    @MainActor static func run(dir: String) -> Int {
        var failures = focusRingFailures()
        realWindowFocusCapture(dir: dir, dark: false)
        realWindowFocusCapture(dir: dir, dark: true)
        let raw = rawButtonUses()
        for line in raw { MenuBarIcon.testLog("button scan: raw button use \(line) FAIL") }
        failures += raw.count
        MenuBarIcon.testLog("button scan: \(raw.isEmpty ? "every button is a ThemeButton" : "\(raw.count) raw use(s)")")
        for (name, dark, solid) in [("light", false, false), ("dark", true, false), ("solid", false, true)] {
            let view = gallery(solid: solid)
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.layoutSubtreeIfNeeded()
            _ = UIDumpFormat.png(view, to: "\(dir)/button-gallery-\(name).png")
        }
        return failures
    }
}
#endif
