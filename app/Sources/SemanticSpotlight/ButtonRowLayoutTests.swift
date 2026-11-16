import AppKit
import SwiftUI

/// A layout probe: in a debug build, a button reports its frame (in the test's root coordinate space) under its id. The
/// probes do nothing in a release build. The button rows the tests measure carry one probe per button.
extension View {
    func layoutProbe(_ id: String) -> some View {
#if DEBUG
        background(GeometryReader { g in
            Color.clear.preference(key: LayoutProbeKey.self, value: [id: g.frame(in: .named(LayoutProbeKey.space))])
        })
#else
        self
#endif
    }
}

#if DEBUG
struct LayoutProbeKey: PreferenceKey {
    static let space = "layoutProbe"
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Test only (run by the theme test): the button rows that are centred measure as rows. For each row: the buttons have
/// equal widths (within 1 pt), equal gaps (within 1 pt), and the left margin equals the right margin (within 1 pt). The
/// frames are the rendered views' own layout (the probes), read after the views are laid out in a window that is never
/// shown. Checked for the uninstall summary (removed, partial), the Settings Advanced and Folders rows, light and dark.
enum ButtonRowLayoutTests {
    /// Lays a view out in a hidden window, and returns the probes' frames (root coordinates) once the layout has settled.
    @MainActor static func layout<V: View>(_ view: V, dark: Bool) -> [String: CGRect] {
        var frames: [String: CGRect] = [:]
        let root = view
            .frame(width: 480)
            .coordinateSpace(name: LayoutProbeKey.space)
            .onPreferenceChange(LayoutProbeKey.self) { frames = $0 }
        let hosting = NSHostingView(rootView: root)
        let window = AppWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 900), styleMask: [.borderless],
                               backing: .buffered, defer: true)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        Headless.moveOffScreen(window)
        window.orderFront(nil)
        hosting.frame = NSRect(x: 0, y: 0, width: 480, height: max(hosting.fittingSize.height, 100))
        for _ in 0..<3 {   // the probes report after a layout pass: run the loop until they have
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        Headless.hide(window)
        window.close()
        return frames
    }

    /// Checks one row, given the probe ids of its buttons from left to right. Calls `check` once per property.
    static func checkRow(_ name: String, _ frames: [String: CGRect], ids: [String], check: (String, Bool, String) -> Void) {
        let row = ids.compactMap { id in frames[id].map { (id, $0) } }
        check("\(name): all \(ids.count) buttons are laid out", row.count == ids.count, "found \(row.map { $0.0 })")
        guard row.count == ids.count, row.count >= 2 else { return }
        let widths = row.map { $0.1.width }
        check("\(name): the buttons have equal widths (within 1 pt)", (widths.max() ?? 0) - (widths.min() ?? 0) <= 1,
              widths.map { String(format: "%.1f", $0) }.joined(separator: ", "))
        let gaps = zip(row, row.dropFirst()).map { $1.1.minX - $0.1.maxX }
        check("\(name): the gaps are equal (within 1 pt)", (gaps.max() ?? 0) - (gaps.min() ?? 0) <= 1,
              gaps.map { String(format: "%.1f", $0) }.joined(separator: ", "))
        let left = row.first!.1.minX
        let right = 480 - row.last!.1.maxX
        check("\(name): the row is centred (left margin equals right margin, within 1 pt)", abs(left - right) <= 1,
              String(format: "left %.1f, right %.1f", left, right))
    }

    @MainActor static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String) {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("button row: \(ok ? "ok" : "FAIL") \(name) (\(detail))")
        }
        for dark in [false, true] {
            let mode = dark ? "dark" : "light"
            for variant in ["removed", "partial"] {
                let model = UninstallModel()
                UninstallModel.testVariant = variant
                model.testShowVariant()
                let frames = layout(UninstallSheet(model: model, close: {}), dark: dark)
                checkRow("summary \(variant) \(mode)", frames, ids: ["summary.copy", "summary.save", "summary.quit"]) { check($0, $1, $2) }
            }
            let working = UninstallModel()
            UninstallModel.testVariant = "working"
            working.testShowVariant()
            check("working \(mode): no button row while removing",
                  layout(UninstallSheet(model: working, close: {}), dark: dark).keys.allSatisfy { !$0.hasPrefix("summary.") }, "")
            UninstallModel.testVariant = "removed"
            let advanced = layout(SettingsView(nav: SettingsNav(measuring: .advanced), welcome: OnboardingModel(), contentHeight: nil), dark: dark)
            checkRow("settings advanced diagnostics \(mode)", advanced, ids: ["diagnostics.copy", "diagnostics.save"]) { check($0, $1, $2) }
            // General: four rows of one style, each 44 pt, with the model row's state in the ready and missing states.
            for (label, state) in [("ready", 3), ("missing", 1)] {
                OnboardingWindow.shared.testSetState(state)
                let general = layout(SettingsView(nav: SettingsNav(measuring: .general), welcome: OnboardingWindow.shared.model,
                                                  contentHeight: nil), dark: dark)
                // The model row is 44 pt when ready; when missing it has the 470 MB caption under it (the rows below stay 44).
                let ids = label == "ready" ? ["general.model", "general.launch", "general.hotkey"] : ["general.launch", "general.hotkey"]
                for id in ids {
                    let h = general[id]?.height ?? 0
                    check("settings general \(label) \(mode): \(id) row is 44 pt", abs(h - SettingsRowMetrics.height) <= 0.5,
                          String(format: "%.1f pt", h))
                }
            }
            let folders = OnboardingModel()
            folders.apply(nil, rows: [FolderRow(id: "/a", path: "/a", text: "6 files", tone: .ok)])
            let folderRows = layout(SettingsView(nav: SettingsNav(measuring: .folders), welcome: folders, contentHeight: nil), dark: dark)
            checkRow("settings folders actions \(mode)", folderRows, ids: ["folders.add", "folders.index"]) { check($0, $1, $2) }
        }
        UninstallModel.testVariant = "removed"
        return failures
    }
}
#endif
