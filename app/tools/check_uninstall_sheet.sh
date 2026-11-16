#!/usr/bin/env bash
# Acceptance test for the uninstall sheet. The sheet is opened in the app over a FAKE HOME shaped like the
# real ~/.semsearch: the real tree is read with find/stat/readlink only (names, sizes, modes, link targets;
# never file contents), and the fake tree is built with empty sparse files. The real ~/.semsearch, the real
# preferences and any running app are never written to, and the app runs with HOME pointing at the fake home.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh

swift build >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build --show-bin-path)/SemanticSpotlight"
REAL="$HOME/.semsearch"
PREFS="$HOME/Library/Preferences/local.semanticspotlight.app.plist"
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-sheet-test.XXXXXX")"
mkdir -p "$W/tmp"
tl_init "$W"
FAKE="$W/home"
APP="$W/app/SemanticSpotlight.app"
C="$W/darwin-cache/"; T="$W/darwin-temp/"
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }

[ "$FAKE" != "$HOME" ] || { echo "refusing: fake home is the real home" >&2; exit 1; }

# Real-tree fingerprint (read-only): names of the real home's top-level entries (the live app's own files excluded), and the prefs mtime.
# The real home's entries, minus the names the app and its engine create themselves (they change while the user's app
# runs), and the prefs mtime, which only counts while no user app runs (the guard in semsearch_home_guard.py decides).
fingerprint() {
    echo "$(ls -A "$REAL" 2>/dev/null | grep -v -E '^(index\.db(-wal|-shm)?|app-daemon\.log|daemon\..*|daemon\.sock|cache|hf|st|torch|tmp|models|config\.json)$' | sort | tr '\n' ' ')"
}
user_app_now() { python3 "$(cd "$(dirname "$0")" && pwd)/semsearch_home_guard.py" running "$REAL/.none" 2>/dev/null; }
prefs_mtime() { stat -f '%m' "$PREFS" 2>/dev/null || echo none; }
REAL_PREFS_BEFORE="$(prefs_mtime)"; REAL_USER_APP_BEFORE="$(user_app_now)"
REAL_BEFORE="$(fingerprint)"

# --- Fake HOME shaped like the real engine home: directories, files with sizes and modes, and symlinks. ---
mkdir -p "$FAKE"
if [ -d "$REAL" ]; then
    (cd "$REAL" && find . -type d -exec stat -f '%Lp %N' {} +) > "$W/dirs.txt"
    (cd "$REAL" && find . -type f -exec stat -f '%z %Lp %N' {} +) > "$W/files.txt"
    (cd "$REAL" && find . -type l) > "$W/links.txt"
    (cd "$REAL" && while IFS= read -r l; do printf '%s\t%s\n' "$l" "$(readlink "$l")"; done < "$W/links.txt") > "$W/linkmap.txt"
    python3 - "$FAKE/.semsearch" "$W/dirs.txt" "$W/files.txt" "$W/linkmap.txt" <<'PY'
import os, sys
root, dirs, files, links = sys.argv[1:5]
os.makedirs(root, exist_ok=True)
def path(name):
    name = name[2:] if name.startswith("./") else name
    return os.path.join(root, name) if name else root
for line in open(files).read().splitlines():             # "<size> <mode> <name>": metadata only
    size, mode, name = line.split(" ", 2)
    p = path(name); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "wb").close(); os.truncate(p, int(size)); os.chmod(p, 0o600)
for line in open(links).read().splitlines():             # "<name>\t<target>"
    name, target = line.split("\t", 1)
    p = path(name); os.makedirs(os.path.dirname(p), exist_ok=True)
    os.symlink(target, p)
dir_modes = []
for line in open(dirs).read().splitlines():              # "<mode> <name>"
    mode, name = line.split(" ", 1)
    os.makedirs(path(name), exist_ok=True); dir_modes.append((path(name), int(mode, 8)))
for p, mode in sorted(dir_modes, key=lambda x: -x[0].count("/")):   # deepest first, so read-only dirs stay writable while filled
    os.chmod(p, mode | 0o700)
PY
    echo "fake engine home: $(find "$FAKE/.semsearch" | wc -l | tr -d ' ') entries, $(find "$FAKE/.semsearch" -type l | wc -l | tr -d ' ') symlinks, $(find "$FAKE/.semsearch" -type d | wc -l | tr -d ' ') dirs (real: $(wc -l < "$W/files.txt") files, $(wc -l < "$W/dirs.txt") dirs)"
else
    echo "no real ~/.semsearch to copy the shape from; using a minimal fake tree"
    mkdir -p "$FAKE/.semsearch/models/models--intfloat--multilingual-e5-small/blobs"
    : > "$FAKE/.semsearch/index.db"; : > "$FAKE/.semsearch/config.json"
fi
mkdir -p "$FAKE/.semsearch/models/.locks" "$FAKE/Library/Preferences" "$FAKE/Library/Caches/local.semanticspotlight.app" \
         "$FAKE/Documents/indexed"
: > "$FAKE/.semsearch/index.db"   # the fixture always has an index, whatever the real home holds
printf 'plist' > "$FAKE/Library/Preferences/local.semanticspotlight.app.plist"
printf 'cache' > "$FAKE/Library/Caches/local.semanticspotlight.app/c.db"
mkdir -p "$C/org.python.python/com.apple.metal" "$C/com.apple.metal" "$T/com.apple.MetalPerformanceShadersGraph/mpsgraph-1"
mkdir -p "$C/local.semanticspotlight.app/com.apple.metal" "$C/local.semanticspotlight.app/com.apple.metalfe" \
         "$C/org.python.python/com.apple.metalfe"   # the engine's Metal folders, keyed by the app and the interpreter
printf 'k' > "$C/local.semanticspotlight.app/com.apple.metal/k"; printf 'k' > "$C/org.python.python/com.apple.metalfe/k"
printf 's' > "$C/org.python.python/com.apple.metal/lib.metallib"; printf 's' > "$C/com.apple.metal/shared"
printf 'g' > "$T/com.apple.MetalPerformanceShadersGraph/mpsgraph-1/g"
printf 'my notes' > "$FAKE/Documents/indexed/notes.txt"; printf 'my photo' > "$FAKE/Documents/keep.txt"

mkdir -p "$APP/Contents/MacOS"; cp "$BIN" "$APP/Contents/MacOS/SemanticSpotlight"
RUN_ENV=(TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$FAKE" SS_UNINSTALL_APP="$APP" SS_UNINSTALL_CACHE_DIR="$C" SS_UNINSTALL_TEMP_DIR="$T")

# --- 1. The sheet opens, the main thread stays responsive, and nothing is deleted yet. ---
env CFFIXED_USER_HOME="$FAKE" HOME="$FAKE" "${RUN_ENV[@]}" "$APP/Contents/MacOS/SemanticSpotlight" --show-uninstall-for-test > "$W/app1.out" 2>&1 &
PID1=$!
tl_track "$PID1"
sleep 3
kill -0 "$PID1" 2>/dev/null && pass "app running with the sheet hook (pid $PID1)" || fail "app exited early: $(tail -3 "$W/app1.out")"
tl_idle_sample "$PID1" "$W/sample1" > "$W/idle1.path" && pass "main thread idle in the run loop in a sample (no alert, no layout)" \
    || fail "main thread in layout or not in the run loop in every sample"
WINS="$(swift "$(dirname "$0")/window_list.swift" "$PID1" 2>/dev/null)"
echo "$WINS" | sed 's/^/      /'
echo "$WINS" | /usr/bin/grep -q "sheet-like" && pass "a sheet-sized window is on screen" || fail "no sheet-sized window found"
[ -f "$FAKE/.semsearch/index.db" ] && [ -f "$FAKE/Documents/keep.txt" ] && pass "nothing deleted before Uninstall" || fail "something was deleted before Uninstall"

# --- 2a. Quit with the sheet still open and nothing confirmed. No autoconfirm: the test hook presses Quit after 2 s. ---
env CFFIXED_USER_HOME="$FAKE" HOME="$FAKE" SS_TEST_PRESS_QUIT=1 "${RUN_ENV[@]}" "$APP/Contents/MacOS/SemanticSpotlight" --show-uninstall-for-test > "$W/app2a.out" 2>&1 &
PID2A=$!
tl_track "$PID2A"
# The sheet's own Quit button (pressed by the test hook) must end the process, and quickly.
quit_within() { # quit_within <pid> <stderr file> <limit seconds> <label>
    local pid="$1" file="$2" limit="$3" label="$4" t_quit t_exit
    for _ in $(seq 150); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    t_exit="$(python3 -c 'import time; print(time.time())')"
    if kill -0 "$pid" 2>/dev/null; then fail "$label: still running 15 s after Quit"; kill -KILL "$pid" 2>/dev/null; return; fi
    t_quit="$(grep -o 'quit-pressed [0-9.]*' "$file" | awk '{print $2}' | tail -1)"
    if [ -z "$t_quit" ]; then fail "$label: no Quit was pressed"; return; fi
    python3 -c "import sys; d = $t_exit - $t_quit; print(f'      $label: exited {d:.2f} s after Quit'); sys.exit(0 if d <= $limit else 1)" \
        && pass "$label: exits within $limit s of pressing Quit" || fail "$label: too slow to quit"
    wait "$pid" 2>/dev/null
}
quit_within "$PID2A" "$W/app2a.out" 3 "Quit with the sheet open, nothing confirmed"
[ -f "$FAKE/.semsearch/index.db" ] && [ -f "$FAKE/Documents/keep.txt" ] && pass "nothing removed by that Quit" || fail "that Quit removed something"

# --- 2. Destructive path (test only: autoconfirm after 2 s). ---
kill "$PID1" 2>/dev/null; sleep 1
env CFFIXED_USER_HOME="$FAKE" HOME="$FAKE" SS_UNINSTALL_AUTOCONFIRM=1 SS_TEST_PRESS_QUIT=1 "${RUN_ENV[@]}" "$APP/Contents/MacOS/SemanticSpotlight" --show-uninstall-for-test > "$W/app2.out" 2>&1 &
PID2=$!
tl_track "$PID2"
for _ in $(seq 60); do [ -e "$FAKE/.semsearch" ] || [ -L "$FAKE/.semsearch" ] || break; sleep 0.1; done
# One sample only: the app quits 2 s after the summary, and sampling pauses the app, so a second sample would
# also delay that Quit.
case "$(tl_idle_sample "$PID2" "$W/sample2" 1 > "$W/idle2.path"; echo $?)" in
    0) pass "main thread answers after Uninstall (idle in a sample)" ;;
    2) fail "app quit before the post-uninstall sample could be taken" ;;
    *) fail "main thread stuck in layout after Uninstall: layout in the sample (frames below)"
    LS="$(cat "$W/idle2.path")"; echo "      last sample $LS: $(wc -c < "$LS" 2>/dev/null) bytes, main-thread headers: $(grep -c -E 'com.apple.main-thread|Main Thread' "$LS" 2>/dev/null), CFRunLoop lines: $(grep -c CFRunLoop "$LS" 2>/dev/null)"
    awk '/com.apple.main-thread|Main Thread/ {on=1; next} on && /Thread_[0-9]+/ {on=0} on' "$LS" | head -6 | cut -c1-150 | sed 's/^/      /' ;;
esac
[ ! -e "$FAKE/.semsearch" ] && [ ! -L "$FAKE/.semsearch" ] && pass "engine home removed (fake HOME)" || fail "engine home still present"
[ ! -e "$FAKE/Library/Preferences/local.semanticspotlight.app.plist" ] && pass "preferences removed (fake HOME)" || fail "preferences still present"
[ -f "$C/org.python.python/com.apple.metal/lib.metallib" ] && pass "shared org.python.python kept (other software uses it)" || fail "shared org.python.python deleted"
[ -f "$C/com.apple.metal/shared" ] && pass "shared com.apple.metal kept" || fail "shared com.apple.metal deleted"
[ "$(cat "$FAKE/Documents/keep.txt" 2>/dev/null)" = "my photo" ] && [ "$(cat "$FAKE/Documents/indexed/notes.txt" 2>/dev/null)" = "my notes" ] \
    && pass "user files untouched" || fail "user files damaged"
quit_within "$PID2" "$W/app2.out" 3 "Quit in the uninstall sheet"
for _ in $(seq 50); do [ -e "$APP" ] || break; sleep 0.1; done   # the helper deletes the copy shortly after the app exits
[ ! -e "$APP" ] && pass "app copy removed by the helper" || fail "app copy still present after 5 s"
[ ! -e "$C/local.semanticspotlight.app" ] && pass "app-keyed GPU cache removed whole" || fail "app-keyed GPU cache still present"
[ -f "$C/org.python.python/com.apple.metalfe/k" ] && [ -f "$T/com.apple.MetalPerformanceShadersGraph/mpsgraph-1/g" ] \
    && pass "shared Metal folders kept: org.python.python and the MPS graph folders" || fail "a shared Metal folder was deleted"

# --- 2b. The menu-bar Quit, pressed by the test hook, on a fresh copy of the app. ---
MENU_APP="$W/menu/SemanticSpotlight.app"; mkdir -p "$MENU_APP/Contents/MacOS"; cp "$BIN" "$MENU_APP/Contents/MacOS/SemanticSpotlight"
cp Resources/Info.plist "$MENU_APP/Contents/Info.plist"; env CFFIXED_USER_HOME="$FAKE" HOME="$FAKE" TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$FAKE" SS_UNINSTALL_APP="$MENU_APP" SS_UNINSTALL_CACHE_DIR="$C" SS_UNINSTALL_TEMP_DIR="$T" \
    "$MENU_APP/Contents/MacOS/SemanticSpotlight" --quit-menu-for-test > "$W/app3.out" 2>&1 &
PID3=$!
tl_track "$PID3"
quit_within "$PID3" "$W/app3.out" 3 "Quit from the menu bar"

# --- 3. The real tree and prefs are exactly as they were. ---
# Unchanged, and the prefs too unless a user app ran at either end (its own writes are not the test's).
REAL_NOW_USER_APP="$(user_app_now)"
if [ "$(fingerprint)" = "$REAL_BEFORE" ] && { [ "$REAL_USER_APP_BEFORE" = yes ] || [ "$REAL_NOW_USER_APP" = yes ] || [ "$(prefs_mtime)" = "$REAL_PREFS_BEFORE" ]; }; then pass "real ~/.semsearch and prefs unchanged"; else fail "real data changed: $REAL_BEFORE -> $(fingerprint)"; fi

if [ "$FAILS" -eq 0 ]; then echo; echo "uninstall sheet check: PASS"; else echo; echo "uninstall sheet check: $FAILS failure(s)"; fi
exit "$FAILS"
