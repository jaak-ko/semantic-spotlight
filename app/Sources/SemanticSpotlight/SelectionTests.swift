#if DEBUG
import AppKit

/// Test only (run by the theme test): the search results' selection. The pointer selects a row only when it moves over
/// it (the view calls `pointerMoved(toRow:)` only on movement); the keyboard continues from there; new results do not
/// select the row under a still pointer.
enum SelectionTests {
    private static func hits(_ n: Int) -> [Hit] {
        (0..<n).map { Hit(id: "\($0)", path: "/fixture/notes/file-\($0).txt", score: 0.5, similarity: nil, snippet: "snippet") }
    }

    @MainActor static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("selection test: \(ok ? "ok" : "FAIL") \(name)")
        }
        let scope = FolderScope(defaults: MemoryPrefs())
        let model = SearchModel(engine: EngineManager.shared, scope: scope)
        model.testSetResults(hits(6), notice: "")

        // The pointer moves over row 3 (index 2): that row is selected.
        model.pointerMoved(toRow: 2)
        check("moving the pointer over row 3 selects it (selection 2)", model.selection == 2)

        // The keyboard continues from the hovered row.
        model.move(1)
        check("keyboard down continues from the hovered row (selection 3)", model.selection == 3)

        // The results change while the pointer stays still: the view does not call pointerMoved, so the row under the
        // pointer is not selected; the results set the selection (the top row, as they always have).
        model.testSetResults(hits(6), notice: "")
        check("stationary pointer with changed results keeps the results' selection (0), not the row under the pointer",
              model.selection == 0)

        // Movement over a row out of range is ignored, and a move to the same row changes nothing.
        model.pointerMoved(toRow: 9)
        check("a row that does not exist is ignored", model.selection == 0)
        model.pointerMoved(toRow: 0)
        check("the same row again keeps the selection", model.selection == 0)

        // The pointer leaving the list is not an event: the last selection stays.
        model.pointerMoved(toRow: 4)
        check("movement over row 5 selects it (selection 4)", model.selection == 4)
        MenuBarIcon.testLog("selection test: done, \(failures) failure(s)")
        return failures
    }
}
#endif
