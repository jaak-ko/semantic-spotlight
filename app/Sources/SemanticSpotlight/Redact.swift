import Foundation

/// Redaction for diagnostics and reports. A pure function: no I/O, no globals, Foundation only.
///
/// - Lines that may hold a search query, a snippet or file content are replaced by a placeholder.
/// - E-mail addresses become `<email>`.
/// - Curly-quoted text (system error texts quote names this way) becomes `“<text>”`.
/// - On skip and warning lines, double-quoted text becomes `"<text>"` (it is often a path).
/// - Every path is cut down to its last name: the extension is kept (`<file>.txt`), a name without one becomes
///   `<folder>`, and the folders in between become `…`. The home folder becomes `~`. Windows paths are handled the same way.
///
/// Limit: a file name that appears without any path around it (inside an error text, for example) is not detected.
enum Redact {
    static func text(_ input: String, home: String) -> String {
        input.components(separatedBy: "\n").map { line(String($0), home: home) }.joined(separator: "\n")
    }

    static func line(_ raw: String, home: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("query") || lower.contains("snippet") || lower.contains("content") {
            return "[line omitted: may contain a query or file content]"
        }
        var s = replace(raw, #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#) { _ in "<email>" }
        // System error texts quote the file name with curly quotes: always redact those.
        s = replace(s, #"“[^”\n]*”"#) { _ in "“<text>”" }
        if lower.contains("skip") || lower.contains("warning") {
            s = replace(s, #""[^"\n]*""#) { _ in "\"<text>\"" }
        }
        s = replace(s, posixPattern) { pathToken($0, home: home) }
        s = replace(s, windowsPattern) { windowsToken($0) }
        return s
    }

    /// A path starts at the start of the line or after a space, bracket, quote, `=`, `:` or `,`, and ends before
    /// " (", a closing quote or bracket, ", ", "; ", ": ", or the end of the line. Spaces and non-ASCII text inside are kept.
    private static let stop = #"(?=\s\(|\s*$|["'`\)\]]|,\s|;\s|:\s)"#
    private static let posixPattern = #"(?:^|(?<=[\s(\[\"'=:,]))/[^\n"'`]*?"# + stop
    private static let windowsPattern = #"[A-Za-z]:\\[^\n"'`]*?"# + stop

    static func pathToken(_ raw: String, home: String) -> String {
        var p = raw
        var tail = ""
        while p.count > 1, let c = p.last, ".,;:".contains(c) {
            tail = String(c) + tail
            p.removeLast()
        }
        var h = home
        while h.count > 1, h.hasSuffix("/") { h.removeLast() }
        if h != "/", p == h { return "~" + tail }
        var prefix = "/"
        var rest = p
        if h != "/", p.hasPrefix(h + "/") {
            prefix = "~/"
            rest = String(p.dropFirst(h.count + 1))
        }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = parts.last else { return prefix + tail }
        return parts.count == 1 ? prefix + name(last) + tail : prefix + "…/" + name(last) + tail
    }

    static func windowsToken(_ raw: String) -> String {
        var p = raw
        var tail = ""
        while p.count > 3, let c = p.last, ".,;:".contains(c) {
            tail = String(c) + tail
            p.removeLast()
        }
        let parts = p.dropFirst(3).split(separator: "\\", omittingEmptySubsequences: true).map(String.init)
        guard let last = parts.last else { return "…" + tail }
        return parts.count == 1 ? name(last) + tail : "…\\" + name(last) + tail
    }

    /// `<file>.ext` when the name ends in a short ASCII extension, otherwise `<folder>`. Hidden names (`.env`) are folders.
    static func name(_ s: String) -> String {
        guard let dot = s.lastIndex(of: "."), dot != s.startIndex else { return "<folder>" }
        let ext = s[s.index(after: dot)...]
        let plain = !ext.isEmpty && ext.count <= 8 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return plain ? "<file>." + ext : "<folder>"
    }

    /// Replaces every match of `pattern` with `transform(match)`.
    static func replace(_ s: String, _ pattern: String, _ transform: (String) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += transform(ns.substring(with: m.range))
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
