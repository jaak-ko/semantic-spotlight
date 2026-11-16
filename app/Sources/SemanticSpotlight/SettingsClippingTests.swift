#if DEBUG
import AppKit
import SwiftUI

/// Test only (run by the theme test): nothing in Settings is clipped. (1) Each tab, in the real window size (the tab bar
/// plus the fixed area), for the model states ready, missing, downloading and failed, with two folders listed: the lowest
/// element of the tab ends at least 16 pt above the window's bottom edge. (2) A tab that does not fit its area scrolls: the
/// scroll view is there and reaches the lowest element. Larger text is not simulated (macOS fonts here are fixed sizes):
/// the scroll fallback is what covers it, and this checks the fallback.
enum SettingsClippingTests {
    static let lowest: [(SettingsTab, String)] = [(.general, "general.privacy"), (.folders, "folders.lowest"), (.advanced, "advanced.version")]

    /// The model states, each with two folders listed.
    static func states() -> [(String, OnboardingModel)] {
        let two = ["/fixture/notes", "/fixture/projects"]
        let rows = two.map { FolderRow(id: $0, path: $0, text: "6 files", tone: .ok) }
        func model(_ configure: (OnboardingModel) -> Void) -> OnboardingModel {
            let m = OnboardingModel()
            m.apply(EngineStatus(["files": 12, "chunks": 30, "folders": two, "indexing": false, "model": "m",
                                  "model_ready": false, "folder_stats": two.map { ["path": $0, "files": 6] }]), rows: rows)
            configure(m)
            return m
        }
        return [
            ("missing", model { _ in }),
            ("ready", model { m in m.apply(EngineStatus(["files": 12, "chunks": 30, "folders": two, "indexing": false,
                                                         "model": "m", "model_ready": true, "folder_stats": []]), rows: rows) }),
            ("downloading", model { m in
                m.download = .running
                m.downloadedBytes = (212_000_000, 470_000_000)
                m.ease.seed(done: 212_000_000, total: 470_000_000)
            }),
            ("failed", model { m in
                m.download = .failed(message: "The download stopped. Check the connection and try again.", detail: "URLError -1009")
            }),
        ]
    }

    /// Lays a view out at a fixed size, as the window holds it; returns the probes' frames (root coordinates) and the view.
    @MainActor static func layout(_ view: some View, size: NSSize) -> ([String: CGRect], NSView) {
        var frames: [String: CGRect] = [:]
        let root = view
            .frame(width: size.width, height: size.height)
            .coordinateSpace(name: LayoutProbeKey.space)
            .onPreferenceChange(LayoutProbeKey.self) { frames = $0 }
        let hosting = NSHostingView(rootView: root)
        let window = AppWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        Headless.moveOffScreen(window)
        window.orderFront(nil)
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        Headless.hide(window)
        window.close()
        return (frames, hosting)
    }

    static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for child in view.subviews { if let found = scrollView(in: child) { return found } }
        return nil
    }

    /// A scroll view is engaged when its document is taller than what it shows.
    static func engaged(_ scroll: NSScrollView) -> Bool {
        (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 0.5
    }

    @MainActor static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("clipping: \(ok ? "ok" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
        }
        let area = SettingsLayout.contentHeight(for: NSScreen.main)
        let windowHeight = SettingsLayout.tabBarHeight + area
        for (state, model) in states() {
            for (tab, probe) in lowest {
                let (frames, _) = layout(SettingsView(nav: SettingsNav(measuring: tab), welcome: model, contentHeight: area),
                                         size: NSSize(width: SettingsLayout.width, height: windowHeight))
                guard let rect = frames[probe] else {
                    check("\(tab.title) \(state): the lowest element is laid out", false, "no probe \(probe)")
                    continue
                }
                let clearance = windowHeight - rect.maxY
                check("\(tab.title) \(state): the lowest element clears the bottom edge by 16 pt", clearance >= 16,
                      String(format: "%.1f pt clearance, area %.0f", clearance, area))
            }
        }
        // The fallback: a tab that is taller than its area scrolls, and the scroll view reaches its lowest element.
        for (tab, probe) in lowest {
            let natural = SettingsLayout.naturalTabHeight(tab, welcome: states()[0].1)
            let small = (natural * 0.8).rounded(.down)
            let smallWindow = SettingsLayout.tabBarHeight + small
            let (frames, hosting) = layout(SettingsView(nav: SettingsNav(measuring: tab), welcome: states()[0].1, contentHeight: small),
                                           size: NSSize(width: SettingsLayout.width, height: smallWindow))
            let scroll = scrollView(in: hosting)
            check("\(tab.title): a tab taller than its area scrolls", scroll.map { engaged($0) } ?? false,
                  String(format: "natural %.0f, area %.0f", natural, small))
            if let rect = frames[probe], let scroll {
                // The probe is in root coordinates; the scroll content starts below the tab bar and the 24 pt padding.
                let docHeight = scroll.documentView?.frame.height ?? 0
                let lowestInContent = rect.maxY - SettingsLayout.tabBarHeight - 24
                check("\(tab.title): the scroll view reaches the lowest element", docHeight >= lowestInContent - 1,
                      String(format: "content %.0f, lowest at %.0f", docHeight, lowestInContent))
            } else {
                check("\(tab.title): the lowest element exists under the scroll", false)
            }
        }
        // A tab that fits its area does not scroll.
        let fitting = SettingsLayout.naturalTabHeight(.advanced, welcome: states()[0].1)
        let (_, fits) = layout(SettingsView(nav: SettingsNav(measuring: .advanced), welcome: states()[0].1,
                                            contentHeight: fitting + 8), size: NSSize(width: SettingsLayout.width, height: SettingsLayout.tabBarHeight + fitting + 8))
        // Engaged means the document is taller than the visible area: a scroll view that merely exists does not scroll.
        let engagedFits = scrollView(in: fits).map { engaged($0) } ?? false
        let detail = scrollView(in: fits).map { "doc \(Int($0.documentView?.frame.height ?? 0)), clip \(Int($0.contentView.bounds.height))" } ?? "no scroll view"
        check("Advanced: a tab that fits its area is not scrolled", !engagedFits, detail)
        return failures
    }
}
#endif
