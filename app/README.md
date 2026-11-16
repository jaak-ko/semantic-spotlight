# Semantic Spotlight (menu bar app)

A small native macOS menu bar app. Press a global hotkey (default **Option+Space**),
type what you remember, and get the files that match by meaning. Nothing leaves
your Mac. The app never modifies your files.

## Build

```bash
cd app
./build.sh          # builds dist/SemanticSpotlight.app and dist/SemanticSpotlight.dmg
```

`build.sh`:
1. runs `swift build -c release`;
2. assembles `dist/SemanticSpotlight.app` (`LSUIElement`, no Dock icon);
3. copies the engine runtime from `../engine/dist/runtime/` into
   `Contents/Resources/runtime/` when it exists (override with `SS_RUNTIME_SRC=...`);
   without a runtime it is a development build that uses the project's `.venv`;
4. ad-hoc signs the whole bundle (`codesign --force --deep -s -`) and verifies it;
5. runs `make_dmg.sh`, which writes `dist/SemanticSpotlight.dmg` (app, `Applications`
   link, `README.txt`). Set `SS_SKIP_DMG=1` to skip the image.

The build fails if the builder's home path or username is in the bundle. The bundled Python and some upstream wheels
still contain other build machines' paths (for example `/Users/runner/...` from CI and docstring examples); those are
upstream strings, not the builder's home, and are accepted, not stripped.

The app is not notarized. The DMG README explains the one-time "Open" step.

### Release and debug builds

- **Release** (`build.sh`, the `.app` and the DMG): the only build anyone installs. It contains no test code. It reads
  none of the test variables (`SS_UNINSTALL_HOME`, `SS_UNINSTALL_APP`, `SS_UNINSTALL_AUTOCONFIRM`, `SS_TEST_*`,
  `SS_DUMP_DIR`, `SS_HEADLESS`), so its uninstall always works on the real home, caches and app bundle. Its data
  folder comes from the account, not from `$HOME`. `strings` on the release binary shows none of those names.
- **Debug** (`swift build`, into `.build/debug`): compiles the test hooks in, behind `#if DEBUG`. Only the check
  scripts in `tools/` use it, with fake homes. Never install or distribute a debug build.

## Engine lookup

1. The runtime bundled in the app: `Contents/Resources/runtime/bin/semsearch`.
2. Development fallback: `engine_path` in `~/.semsearch/config.json`, then the
   parents of the app bundle, looking for `.venv/bin/semsearch`.

Data always stays in `~/.semsearch/`. The app honors `$HOME`, as the engine does.

The app starts `semsearch daemon` when it is not reachable, restarts it if it dies,
and sends SIGTERM on quit. A daemon you started yourself is left alone.
Engine logs go to `~/.semsearch/app-daemon.log`.

## First run

The welcome window opens at launch while the language model is missing or no folder
is registered. It is one column, about 380 pt wide, and shows one task at a time, in
four states (three dots show the step):

1. **Download the language model.** The only network use, and it only runs when you
   click **Download model** (470 MB, once). The button is the only filled control.
2. **Downloading.** A slim progress bar and the byte count; while retrying, "Retrying
   (2 of 5)…"; on failure, the friendly message, **Try again**, and **Show details**.
3. **Language model ready.** **Choose folder…** (NSOpenPanel). It is disabled until
   the model is ready.
4. **Folder indexed.** Folder rows (inline progress while indexing, then a check; Remove
   appears on hover), **Add another folder**, and **Start searching**, which closes the
   window.

**Later** closes the window in states 1 to 3. Click **Start searching** when a folder
is indexed. The window does not reopen automatically after that. Settings has a
**Welcome Screen…** button.

Every button in the app is a capsule from one button system: primary (solid orange, one
per view), secondary (grey wash), tertiary (text only), destructive (red wash; solid red
only for the final confirm). Regular is 38 pt, compact 24 pt.

Engine contract used here: `fetch-model` prints one JSON object per line
(`progress`, then `done` or `error`). `status` returns `model_ready`.

## Images

Images in watched folders are indexed by the text inside them, using the on-device `ocr-helper` bundled in `Contents/Resources/runtime/bin`. Nothing extra to configure.

## Using it

- **Hotkey** opens the search panel. Type; results appear after about 150 ms (up to 8).
- **Up / Down** select a result. Moving the pointer over a row selects it too, like Spotlight
  (only real pointer movement does: a row that scrolls under a still pointer keeps the
  selection). The keyboard continues from the hovered row. **Return** or a click opens the
  selected file. **Cmd+Return** reveals it in Finder.
- **Tab** moves focus to the result list. **Space** then toggles a Quick Look preview.
  While the field has focus, Space types a space. Typing returns focus to the field.
- **Esc** or clicking away closes the panel.
- **Folder scope**: the chip at the right end of the search row shows **All folders**, or `2/3 folders`
  when some folder is left out. Hover it, click it, or Tab to it (then Return or Space) to
  open the list: a checkbox per folder with its name, its parent path, and its file count;
  **All** and **None** (pill buttons; each is disabled when it would change nothing), and the note
  "Only changes what is searched. Nothing is deleted." Hover
  opens the list, and it closes 150 ms after the pointer leaves the chip and the list. A
  click pins it until the next click, Esc, or a click elsewhere. The list never takes the
  keyboard from the search field. A change re-runs the current query. With no folder selected,
  the list says "No folders selected". The excluded folders are stored in the app's
  preferences (`searchExcludedFolders`), so a folder added later is searched by default.
- **Moving the panel**: drag it from anywhere on the header (the top row, the text field included) or the footer (the key hints). A drag from the field moves the panel and does not select text. The scope chip and the result rows do not start a drag. A plain click still places the caret in the field; select text with double-click or with the keyboard. Its place is remembered per screen (`searchPanelPositions`). The first show, or a double-click on the empty lens or right margin of the top row, returns it to the default place: centered, in the upper part of the screen the pointer is on. A remembered place that no longer fits its screen is ignored.
- **Footer (key hints)**: always shown at the bottom of the panel: ↩ open, ⌘↩ show in Finder, Space preview, Esc close.
- **Glass**: every surface uses one glass implementation: the panel, the popover, the welcome and Settings windows, and the sheets. The fill is the system material under a 60% tint; text sits directly on the glass (no cards behind it). Under Reduce Transparency the fill is the solid panel colour.
- **The folder list animates**: it fades and slides 6 px into place in 140 ms (ease-out), and fades out in 100 ms. With Reduce Motion on it appears and disappears at once.
- **Menu bar icon**: a plain, static magnifying glass (a template image). It does not animate; indexing shows in the progress row of the menu. Top to bottom: the engine line, the counts and model, a progress
  row with a bar while indexing, one **Folders (N)** row, a separator, then Reindex Now,
  Show Search, Settings and Quit.
  - The Folders row's title carries a summary: **All ready**, **Indexing k of n** (k folders
    are no longer busy), or the problems in plain words: **N failed to add**, **N with no
    supported files**. A problem is always named, even while folders are still indexing.
  - Its submenu lists every folder with its state. Each folder has a submenu with its state
    and **Remove**. **Add Folder…** is at the bottom of the submenu.
  - Only the progress row and the counts change while indexing. The menu is rebuilt only
    when its structure changes (a folder's state, the engine running or not, the model).
    Nothing is rebuilt while the menu or a submenu is open; the change waits until it closes.
- **Settings**: hotkey (click the button, press a combo with ⌘ ⌥ or ⌃; Esc cancels),
  Launch at login (off by default), engine path, Welcome Screen.

Indexing runs on launch. FSEvents watches the registered folders, and changes trigger
a reindex after 5 s of quiet.

## Protocol

Newline-delimited JSON over the Unix socket `~/.semsearch/daemon.sock`, one request
per connection. Commands used: `status`, `query`, `index`, `add`, `remove`.
The implementation is `Sources/SemanticSpotlight/Engine.swift`.

## Uninstall

**Settings → Uninstall** (bottom of the Settings window): **Uninstall Semantic Spotlight…**. A dialog lists
everything the app created, with sizes, and asks once. Then the app:

- stops its engine (SIGTERM, then SIGKILL if needed) and stops watching folders;
- unregisters the login item and deletes its preferences;
- deletes `~/.semsearch` (index, settings, socket, logs, models, and the caches under it), the
  macOS GPU shader caches the engine causes (rebuilt automatically; the shared `com.apple.metal`
  folder is kept), and the app's Library items: preferences, saved state, caches, web storage, Application Support, Logs,
  and LaunchAgents plist;
- hands the app bundle to a helper that deletes it after the app quits (falls back to
  the Trash if deletion is refused). A read-only disk image is reported, not changed.

Only exact known paths are deleted, never wildcards. Symlinks are removed, never followed.
Your own files and indexed folders are never touched. Inventory: `app/Sources/SemanticSpotlight/Uninstall.swift`.
Afterwards the summary lists what was removed, what could not be removed and why, and what is
still present. **Copy report** and **Save report…** give the same redacted text. Nothing is
written to a log file for the uninstall.

Test without touching real data: `app/tools/check_uninstall.sh` (inventory and removal) and
`app/tools/check_uninstall_sheet.sh` (the sheet, with a fake HOME shaped like a real engine home).

## Headless tests

Every check script builds the debug build (`swift build`, see the release and debug builds above) and sets
`SS_HEADLESS=1` (see `tools/testlib.sh`). Headless, the app puts nothing
on the user's screen: no status item (a fake host is used), windows are transparent and far
off-screen, and the app never activates. `app/tools/check_menu_stress.sh` drives the menu with
random engine states, opens and closes the menu and its Folders submenu (simulated through the
menu's delegate, never popped up), and checks that nothing is rebuilt while open, that progress
ticks never rebuild, that every item is new when made, and the summary wording. It refuses to
run without `SS_HEADLESS=1`. `app/tools/check_all.sh` runs every check, with the clean-state
guard (`app/tools/check_clean_state.sh`) after each one.

## What the uninstall does not remove

Your own files and the folders you indexed are left alone, and nothing about them is listed.

"Not removed" lists only things the app created that are still present after the run, each with the
reason and the command or Finder step that finishes it:

- a file or folder the app could not delete (for example, inside a read-only folder), with the reason
  and a `chmod u+w … && rm -rf …` command;
- a Login Items entry macOS would not let the app unregister (System Settings → General → Login Items);
- a permission reset that failed: the exact `/usr/bin/tccutil reset All local.semanticspotlight.app` command;
- anything the final verification pass still finds.

If nothing is left, the summary says "Everything the app created was removed." The app bundle is deleted by
a helper after the app quits; if it can only be moved to the Trash, the summary says so.
The copied and saved report carries the same list, with paths redacted.

## Diagnostics

**Settings → Diagnostics** (bottom of the Settings window) builds a plain-text report for a support request:
app and macOS versions, chip, whether the model is installed, the engine's status (running, indexing,
number of files, chunks and folders, never their names), the config values for `model`,
`ocr_languages` and `min_similarity`, the login-item state, the hotkey, and the last 200 lines of
the engine log.

- **Copy diagnostics…** and **Save diagnostics file…** open a preview first. Only the buttons in that
  preview copy or save; nothing is sent, and no network code exists in the app.
- The text is redacted by `Redact` (`app/Sources/SemanticSpotlight/Redact.swift`): the home folder becomes
  `~`, every other path is cut to its last name (`~/…/<file>.txt`, `~/…/<folder>`), e-mail addresses
  become `<email>`, quoted text on skip and warning lines is removed, and lines that may hold a query, a
  snippet or content are replaced. A file name that appears with no path around it (inside some error
  text) is not detected; curly-quoted names in system error texts are.
- A saved file is created with mode 0600 in the location you pick (the Desktop by default), and the app
  never remembers or deletes it. Nothing is written to a temporary place.
- Tests: `app/tools/check_redaction.sh` (the pure function, with assert-based cases) and
  `app/tools/check_diagnostics.sh` (a real engine in a fake HOME, a realistic log, the copy and save
  results, the uninstall report, and a responsiveness sample).

## Privacy

- No network code in the app. `Resources/SemanticSpotlight.entitlements` requests no
  network entitlement. The only network use is the engine's `fetch-model`, which
  runs only when the user clicks the download button.
- No telemetry. App Sandbox is not used.

## Known issues / troubleshooting

- **SwiftPM fails with `Undefined symbols … PackageDescription.Package.__allocating_init`
  or `redefinition of module 'SwiftBridging'`**: the Command Line Tools install is broken.
  Reinstall it:
  ```bash
  sudo rm -rf /Library/Developer/CommandLineTools
  xcode-select --install
  ```
- **Gatekeeper on the friend's Mac**: see `Resources/DMG-README.txt`. Not verified on a
  second Mac.
