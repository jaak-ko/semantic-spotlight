#if DEBUG
import AppKit

/// Test only (`--menu-icon-test-for-test`, test roots, headless): the menu-bar logo is assigned once and never changes. A
/// simulated startup (engine down, starting, up, indexing, idle, down) runs through the real StatusMenu on a real
/// NSStatusBarButton that is never placed in the menu bar. The rendered pixels are hashed in light and in dark.
enum MenuIconTests {
    /// A status item host with a real button, so the icon is installed on a real button.
    private final class ButtonHost: MenuBarHost {
        var menu: NSMenu?
        let button: NSStatusBarButton? = NSStatusBarButton(frame: NSRect(x: 0, y: 0, width: 24, height: 22))
    }

    private static func hash(_ image: NSImage, dark: Bool) -> String {
        var result = ""
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        appearance.performAsCurrentDrawingAppearance {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
            NSGraphicsContext.restoreGraphicsState()
            var h: UInt64 = 14695981039346656037
            for byte in rep.bitmapData.map({ Data(bytes: $0, count: rep.bytesPerRow * 36) }) ?? Data() {
                h = (h ^ UInt64(byte)) &* 1099511628211
            }
            var inked = 0
            for y in 0..<36 { for x in 0..<36 { if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 } } }
            result = String(h, radix: 16) + "/ink\(inked)"
        }
        return result
    }

    static func run() {
        let host = ButtonHost()
        let before = MenuBarIcon.assignments
        let menu = StatusMenu(host: host)
        let image = host.button?.image
        let states: [(String, EngineStatus?, String)] = [
            ("engine down", nil, "Starting engine…"),
            ("starting", nil, "Starting engine…"),
            ("up, idle", status(indexing: false), "Running"),
            ("indexing", status(indexing: true), "Running"),
            ("idle again", status(indexing: false), "Running"),
            ("engine down again", nil, "Engine not found. Reinstall the app."),
        ]
        var lines: [String] = []
        var sameObject = true
        var stable = true
        var lightHash: String?, darkHash: String?
        for (name, status, message) in states {
            menu.update(status, message, rows: [])
            menu.updateProgress(status)
            if host.button?.image !== image { sameObject = false }
            let light = hash(host.button?.image ?? NSImage(), dark: false)
            let dark = hash(host.button?.image ?? NSImage(), dark: true)
            if lightHash == nil { lightHash = light; darkHash = dark }
            if light != lightHash || dark != darkHash { stable = false }
            lines.append("\(name): light \(light), dark \(dark)")
        }
        let assigned = MenuBarIcon.assignments - before
        for line in lines { MenuBarIcon.testLog("menu icon: \(line)") }
        MenuBarIcon.testLog("menu icon: assigned \(assigned) time(s) over \(states.count) states")
        MenuBarIcon.testLog(assigned == 1 && sameObject && stable ? "menu icon: ok the logo is assigned once and identical in every state"
                            : "menu icon: FAIL the logo changed (assigned \(assigned), same object \(sameObject), identical pixels \(stable))")
        MenuBarIcon.testLog("menu icon: done")
        _ = menu
        AppQuit.now()
    }

    private static func status(indexing: Bool) -> EngineStatus {
        EngineStatus(["files": 3, "chunks": 9, "folders": ["/fixture/a"], "indexing": indexing, "model": "m", "model_ready": true,
                      "progress": ["phase": indexing ? "indexing" : "idle", "done": 1, "total": 3]])
    }
}
#endif
