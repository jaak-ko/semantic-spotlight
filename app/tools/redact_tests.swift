// Assert-based tests for Redact (compiled together with Sources/SemanticSpotlight/Redact.swift by check_redaction.sh).
import Foundation

var failures = 0
var checks = 0
func expect(_ input: String, _ want: String, home: String = "/Users/testuser", file: String = #file, line: Int = #line) {
    checks += 1
    let got = Redact.text(input, home: home)
    if got != want {
        failures += 1
        print("FAIL line \(line): input  \(input)\n           want   \(want)\n           got    \(got)")
    }
}

// Home paths: the home folder becomes ~, and only the last name survives.
expect("opened /Users/testuser/Documents/a/b.txt", "opened ~/…/<file>.txt")
expect("home is /Users/testuser", "home is ~")
expect("folder /Users/testuser/Desktop", "folder ~/<folder>")
expect("/Users/testuser/notes.md", "~/<file>.md")
// Lookalike home: /Users/testuserX is not the home folder.
expect("skip /Users/testuserX/Documents/z.pdf: too big", "skip /…/<file>.pdf: too big")

// Spaces and non-ASCII names (ä, ö), with the message after a colon kept.
expect("skip /Users/testuser/Documents/Ääkkönen työ/raportti öljy.docx: image larger than limit",
       "skip ~/…/<file>.docx: image larger than limit")
expect("warning: could not read /Users/testuser/Documents/projects/notes 2026/Kesäkuu.txt: Permission denied",
       "warning: could not read ~/…/<file>.txt: Permission denied")

// Nested folders outside the home.
expect("skip /Volumes/Drive/a/b/c/notes.md: symlink resolves outside /Volumes/Drive/a",
       "skip /…/<file>.md: symlink resolves outside /…/<folder>")
expect("skip /Users/other/x/y/z: gone", "skip /…/<folder>: gone")

// E-mail addresses.
expect("mail someone@example.org failed", "mail <email> failed")
// An event's message field (the diagnostics report redacts every event line again): a path and an e-mail, both redacted.
expect("2026-11-10 12:00 warn index_error message=could not read /Users/testuser/Documents/a/b.txt for someone@example.org",
       "2026-11-10 12:00 warn index_error message=could not read ~/…/<folder> <email>")
expect("sent to a.b+c@example.co.uk now", "sent to <email> now")

// A path inside quotes on a warning line: the whole quoted text goes.
expect("warning: could not read \"/Users/testuser/Documents/My Notes/x.txt\"", "warning: could not read \"<text>\"")
expect("skip \"/Users/testuser/Ä/ö file.pdf\" (unsupported)", "skip \"<text>\" (unsupported)")

// Windows paths and odd characters.
expect("skip C:\\Users\\testuser\\Documents\\Notes ä\\raportti.docx: too big", "skip …\\<file>.docx: too big")
expect("skip /Users/testuser/Documents/a&b#c/d%e.txt (x)", "skip ~/…/<file>.txt (x)")
expect("skip /Users/testuser/Documents/tricky;name.v2.txt: odd", "skip ~/…/<file>.txt: odd")
expect("path with trailing dot /Users/testuser/Documents/x.pdf.", "path with trailing dot ~/…/<file>.pdf.")

// System error texts quote the file name with curly quotes.
expect("Could not remove: ~/x: “local.semanticspotlight.app” couldn’t be removed because you don’t have permission",
       "Could not remove: ~/x: “<text>” couldn’t be removed because you don’t have permission")

// Lines that may hold a query, a snippet or content are replaced.
expect("query \"budget 2025\" returned 8", "[line omitted: may contain a query or file content]")
expect("snippet: Discussed the budget", "[line omitted: may contain a query or file content]")

// Lines without paths or names are unchanged.
expect("index: 26 files, 130 chunks", "index: 26 files, 130 chunks")
expect("index settings changed (abc123): rebuilding index", "index settings changed (abc123): rebuilding index")

// Several lines at once keep their line breaks.
expect("a /Users/testuser/x.txt\nb /Users/testuser/y/z", "a ~/<file>.txt\nb ~/…/<folder>")

// Names: extension rules.
checks += 1
if Redact.name(".env") != "<folder>" || Redact.name("archive.tar.gz") != "<file>.gz" || Redact.name("v1.2 notes") != "<folder>" {
    failures += 1
    print("FAIL: name() rules")
}

print("redaction checks: \(checks), failures: \(failures)")
exit(failures == 0 ? 0 : 1)
