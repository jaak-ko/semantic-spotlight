#if DEBUG
import AppKit
import SwiftUI

/// Test only (run by the theme test): a folder row is one line at 380 and 480 pt, whatever the path's length; the name is
/// never truncated (it fits beside the icon, the count and the Remove slot), only the path gives way; a row being indexed
/// is one line plus its bar. Short and long names and paths.
enum FolderRowLayoutTests {
    @MainActor static func run() -> Int {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            if !ok { failures += 1 }
            MenuBarIcon.testLog("folder row: \(ok ? "ok" : "FAIL") \(name)\(detail.isEmpty ? "" : " (\(detail))")")
        }
        let short = ("notes", "/fixture/notes")
        let long = ("Client Archive 2024 Deliverables", "/Users/fixture/Documents/Projects/Client Archive 2024/Deliverables/Final Versions/Round Three/Contracts and Scans")
        let count = "10 files"
        let countFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        // The Remove slot's width, as the button lays it out.
        let remove = NSHostingView(rootView: ThemeButton("Remove", role: .tertiary, size: .compact) {})
        remove.layoutSubtreeIfNeeded()
        let removeWidth = remove.fittingSize.width
        for width: CGFloat in [380, 480] {
            func height(_ row: FolderRow, indexLine: String = "") -> CGFloat {
                let host = NSHostingView(rootView: FolderRowView(row: row, count: count, indexLine: indexLine).frame(width: width))
                host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
                host.layoutSubtreeIfNeeded()
                return host.fittingSize.height
            }
            let ok = { (p: (String, String)) in FolderRow(id: p.1, path: p.1, text: count, tone: .ok) }
            let hShort = height(ok(short)), hLong = height(ok(long))
            check("\(Int(width)) pt: a long path stays on the same line as a short one", abs(hShort - hLong) < 0.5,
                  "\(Int(hShort)) vs \(Int(hLong)) pt")
            let oneLine = hShort < 52 + 12   // 52: the padding and the line; a second line adds at least 14
            check("\(Int(width)) pt: an indexed row is one line", oneLine, "\(Int(hShort)) pt")
            for (label, p) in [("short", short), ("long", long)] {
                let nameWidth = NSAttributedString(string: (p.1 as NSString).lastPathComponent, attributes: [.font: nameFont]).size().width
                let countWidth = NSAttributedString(string: count, attributes: [.font: countFont]).size().width
                // icon 16, gaps 8 before and after the name, after the path, after the count: the name's room is the rest.
                let needed = 16 + 8 + nameWidth + 8 + countWidth + 8 + removeWidth
                check("\(Int(width)) pt, \(label) name is not truncated", needed <= width,
                      "needs \(Int(needed)) of \(Int(width)) pt")
            }
            let busy = FolderRow(id: long.1, path: long.1, text: "Indexing…", tone: .busy)
            let hBusy = height(busy, indexLine: "15 of 309")
            check("\(Int(width)) pt: a row being indexed adds only its bar under the row", hBusy > hShort && hBusy < hShort + 16,
                  "\(Int(hBusy)) vs \(Int(hShort)) pt")
        }
        return failures
    }
}
#endif
