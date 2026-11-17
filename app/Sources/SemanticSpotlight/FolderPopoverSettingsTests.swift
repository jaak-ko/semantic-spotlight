#if DEBUG
import AppKit
import SwiftUI

/// Test only (run by the theme test): the folder popover's Settings button. (1) It exists and is reachable: a probe inside
/// the popover, at least 24 pt on each side, to the right of All and None. (2) A click on it (mouse down and up, sent to a
/// hidden window, so nothing reaches the screen) runs the action the popover was given, once.
enum FolderPopoverSettingsTests {
    private final class Box {
        var frames: [String: CGRect] = [:]
        var clicks = 0
    }

    @MainActor static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("popover settings: \(ok ? "ok" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
        }
        let scope = FolderScope(defaults: MemoryPrefs())
        scope.reconcile(EngineStatus(["files": 9, "chunks": 30, "folders": ["/fixture/notes", "/fixture/projects"], "indexing": false,
                                      "model": "m", "model_ready": true,
                                      "folder_stats": [["path": "/fixture/notes", "files": 6], ["path": "/fixture/projects", "files": 3]]]))
        let model = SearchModel(engine: EngineManager.shared, scope: scope)
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            let box = Box()
            let root = FolderPopoverView(model: model, scope: scope, onHover: { _ in }, onSettings: { box.clicks += 1 })
                .frame(width: FolderPopoverController.width)
                .coordinateSpace(name: LayoutProbeKey.space)
                .onPreferenceChange(LayoutProbeKey.self) { box.frames = $0 }
            let hosting = NSHostingView(rootView: root)
            let window = AppWindow(contentRect: NSRect(x: 0, y: 0, width: FolderPopoverController.width, height: 400),
                                   styleMask: [.borderless], backing: .buffered, defer: true)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = hosting
            Headless.moveOffScreen(window)
            window.orderFront(nil)
            hosting.frame = NSRect(x: 0, y: 0, width: FolderPopoverController.width, height: max(hosting.fittingSize.height, 100))
            for _ in 0..<3 {   // the probes report after a layout pass
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            guard let button = box.frames["popover.settings"], let all = box.frames["popover.all"] else {
                check("\(mode): the Settings button is laid out in the popover", box.frames["popover.settings"] != nil,
                      "probes \(box.frames.keys.sorted())")
                Headless.hide(window)
                window.close()
                continue
            }
            let inside = button.minX >= 0 && button.maxX <= FolderPopoverController.width && button.minY >= 0
            check("\(mode): the Settings button is inside the popover", inside, "\(button)")
            check("\(mode): the Settings button hit area is at least 24 x 24 pt",
                  button.width >= 24 && button.height >= 24, String(format: "%.0f x %.0f", button.width, button.height))
            check("\(mode): the Settings button is clear of All and None", button.minX > all.maxX, "\(button.minX) vs \(all.maxX)")
            // A click: mouse down and up at the button's centre, sent to the hidden window.
            let centre = hosting.convert(NSPoint(x: button.midX, y: button.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: centre, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                  pressure: type == .leftMouseDown ? 1 : 0) {
                    window.sendEvent(event)
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            check("\(mode): a click on the button runs its action once", box.clicks == 1, "clicks \(box.clicks)")
            Headless.hide(window)
            window.close()
        }
        return failures
    }
}
#endif
