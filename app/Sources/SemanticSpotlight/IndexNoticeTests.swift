#if DEBUG
import Foundation

/// Test only (run by the theme test): the quiet index lines. A status payload with `rebuilding` and `files_partial` (both
/// top level) sets them; an older engine sends neither and gets no line. An empty search while rebuilding says so.
enum IndexNoticeTests {
    static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("index notice: \(ok ? "ok" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
        }
        let notes = "/fixture/notes", archive = "/fixture/archive"
        let rebuilding: [String: Any] = [
            "files": 40, "chunks": 90, "folders": [notes, archive], "indexing": false, "model": "m", "model_ready": true,
            "rebuilding": true, "files_partial": 3,
            "folder_stats": [["path": notes, "files": 30], ["path": archive, "files": 10]],
        ]
        let s = EngineStatus(rebuilding)
        check("rebuilding read from the top level", s.rebuilding)
        check("files_partial read from the top level", s.filesPartial == 3)
        let older = EngineStatus(["files": 40, "chunks": 90, "folders": [notes], "indexing": false,
                                  "model": "m", "model_ready": true])
        check("an older engine: no rebuild line", !older.rebuilding)
        check("an older engine: no partial line", older.filesPartial == 0)
        check("rebuild line text", IndexNotice.rebuilding
              == "Updating the search index for better results. Search works more fully as files are indexed.")
        check("partial line, plural", IndexNotice.partial(3)
              == "3 large files are only partly indexed. Their names are always searchable.")
        check("partial line, singular", IndexNotice.partial(1)
              == "1 large file is only partly indexed. Its name is always searchable.")
        check("empty search while rebuilding says the results are partial",
              SearchModel.emptyNotice(rebuilding: true) == IndexNotice.rebuilding)
        check("empty search when not rebuilding keeps the plain line",
              SearchModel.emptyNotice(rebuilding: false) == "No good matches")
        let model = OnboardingModel()
        model.apply(s, rows: [])
        check("the Folders tab shows the rebuild line", model.rebuilding)
        check("the Folders tab shows the partial count", model.filesPartial == 3)
        model.apply(older, rows: [])
        check("an older status clears both lines", !model.rebuilding && model.filesPartial == 0)
        return failures
    }
}
#endif
