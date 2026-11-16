// Lists the on-screen windows of one process. Prints "sheet-like" for a window 440-560 pt wide,
// which is the size of the uninstall sheet. Window names are not read (no Screen Recording needed).
import CoreGraphics
import Foundation

let pid = Int32(CommandLine.arguments.dropFirst().first ?? "") ?? -1
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
var count = 0
for w in windows where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = (b["Width"] as? Double) ?? 0
    let height = (b["Height"] as? Double) ?? 0
    let tag = (440...560).contains(width) ? "sheet-like" : "other"
    print("window \(w[kCGWindowNumber as String] ?? 0): \(Int(width))x\(Int(height)) layer \(w[kCGWindowLayer as String] ?? 0) \(tag)")
    count += 1
}
print("windows for pid \(pid): \(count)")
