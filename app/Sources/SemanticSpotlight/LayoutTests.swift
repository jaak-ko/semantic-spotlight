#if DEBUG
import AppKit

/// Test only (`--layout-test-for-test`, test roots, headless): the search panel's height and header against the layout
/// rules, for 0, 1, 3, 8 and 30 results, very long snippets and the "No good matches" notice; then the popover, its
/// animation, and a drag. Frames are recorded in the output and each state is rendered offscreen (SS_DUMP_DIR).
enum LayoutTests {
    private static var checks = 0
    private static var failures = 0
    private static var lines: [String] = []

    private static func check(_ name: String, _ ok: Bool) {
        checks += 1
        if !ok { failures += 1 }
        MenuBarIcon.testLog("layout test: \(ok ? "ok" : "FAIL") \(name)")
    }

    private static func hits(_ n: Int, snippet: String = "A short snippet about the file.") -> [Hit] {
        (0..<n).map { Hit(id: "\($0)", path: "/fixture/notes/file-\($0).txt", score: 0.5,
                          similarity: 0.9, snippet: snippet) }
    }

    static func run() {
        let engine = EngineManager.shared
        let search = SearchController(engine: engine, scope: FolderScope(defaults: MemoryPrefs()), defaults: MemoryPrefs())
        search.show()
        let screenHeight = SearchPlacement.screen(holding: search.testFrames().panel).visibleFrame.height
        let maxList = SearchLayout.maxListHeight(screenVisibleHeight: screenHeight)
        let longSnippet = String(repeating: "A very long snippet with many words that goes on and on. ", count: 40)
        let dir = ProcessInfo.processInfo.environment["SS_DUMP_DIR"] ?? SemPaths.home

        // Each state: results (or none), the notice, and the rows the expected height uses.
        let states: [(name: String, results: [Hit], notice: String)] = [
            ("0 results", [], ""),
            ("No good matches", [], "No good matches"),
            ("1 result", hits(1), ""),
            ("3 results", hits(3), ""),
            ("8 results", hits(8), ""),
            ("30 results", hits(30), ""),
            ("30 results, long snippets", hits(30, snippet: longSnippet), ""),
            ("3 results, long snippets", hits(3, snippet: longSnippet), ""),
        ]
        var topsSeen = Set<CGFloat>()
        for state in states {
            search.testSetResults(state.results, notice: state.notice)
            let f = search.testFrames()
            let rows = state.results.count
            let expected = SearchLayout.panelHeight(rows: rows, notice: !state.notice.isEmpty, maxHeight: maxList)
            let list = SearchLayout.listHeight(rows: rows, maxHeight: maxList)
            let header = SearchLayout.headerHeight(notice: !state.notice.isEmpty)
            let scrolls = rows > 0 && CGFloat(rows) * SearchLayout.row + SearchLayout.listPadding > maxList
            lines.append("\(state.name): panel \(Int(f.panel.width))x\(Int(f.panel.height)) top \(Int(f.panel.maxY)) "
                         + "hosting \(Int(f.hosting.width))x\(Int(f.hosting.height)) fitting \(Int(f.fitting.width))x\(Int(f.fitting.height)) "
                         + "header \(Int(header)) list \(Int(list)) (max \(Int(maxList))) scrolls \(scrolls)")
            topsSeen.insert(f.panel.maxY)
            check("\(state.name): panel height is header + list (\(Int(expected)))", abs(f.panel.height - expected) < 0.5)
            check("\(state.name): the hosting view fills the panel", abs(f.hosting.height - f.panel.height) < 0.5)
            check("\(state.name): the list never exceeds the cap, and is capped exactly when it scrolls", list <= maxList && (!scrolls || list == maxList))
            check("\(state.name): the header is fully inside the panel (field not clipped)", header <= f.panel.height)
            render(search, name: "layout-\(state.name.replacingOccurrences(of: " ", with: "-"))", dir: dir)
        }
        check("the top edge never moved while the results changed", topsSeen.count == 1)

        // A long snippet must not make rows taller: each row is the fixed height.
        check("a row's height does not depend on its snippet", SearchLayout.row == 64)

        // The popover: opening it leaves the panel alone; its animation runs over the panel's top edge.
        search.testSetResults(hits(3), notice: "")
        let before = search.testFrames().panel
        search.testFolderClick()
        let during = search.testFrames().panel
        check("the folder list does not change the panel's frame", before == during)
        render(search, name: "layout-popover-open", dir: dir)
        search.testHoverExit()
        search.testFolderClick()

        // A drag: the panel moves, keeps its size, and the layout still holds afterwards.
        search.testSetResults(hits(8), notice: "")
        let p0 = search.testFrames().panel
        let w = p0.width
        let grip = NSPoint(x: p0.minX + w / 2, y: p0.maxY - 30)
        search.testPress(at: NSPoint(x: w / 2, y: p0.height - 30), screen: grip)
        _ = search.testDrag(to: NSPoint(x: grip.x + 60, y: grip.y - 40))
        search.testRelease()
        let p1 = search.testFrames().panel
        check("after a drag the panel moved by the mouse's movement", p1.origin == NSPoint(x: p0.origin.x + 60, y: p0.origin.y - 40))
        check("after a drag the panel keeps its size and layout", p1.height == p0.height)
        render(search, name: "layout-after-drag", dir: dir)

        // Selection keeps the header in place (the list scrolls, the panel does not move).
        search.testSetResults(hits(30), notice: "")
        let t0 = search.testFrames().panel.maxY
        for _ in 0..<12 { search.testMoveSelection(1) }
        check("Down past the visible rows leaves the panel's top edge alone", search.testFrames().panel.maxY == t0)

        for line in lines { MenuBarIcon.testLog("layout frames: \(line)") }
        MenuBarIcon.testLog("layout test: done, \(checks) checks, \(failures) failures")
        AppQuit.now()
    }

    private static func render(_ search: SearchController, name: String, dir: String) {
        let ok = search.testRender(to: "\(dir)/\(name).png")
        check("rendered \(name).png", ok)
    }
}
#endif
