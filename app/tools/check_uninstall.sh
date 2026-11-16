#!/usr/bin/env bash
# Tests the uninstall path against fake data. The real ~/.semsearch, the real ~/Library, the real per-user
# GPU caches and the running app are never touched: every root is injected to a fresh temp directory, and
# the test refuses to run if its fake home is the real home. Uses the hidden --uninstall-for-test and
# --list-inventory entry points.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh

swift build >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build --show-bin-path)/SemanticSpotlight"
DOC="../engine/UNINSTALL_INVENTORY.md"
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-uninstall-test.XXXXXX")"
tl_init "$W"
mkdir -p "$W/tmp"
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }
gone() { [ ! -e "$1" ] && [ ! -L "$1" ]; }

# Every run gets test roots only: home, app bundle, GPU cache root, GPU temp root.
run() {
    OUT="$(TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$1" SS_UNINSTALL_APP="$2" SS_UNINSTALL_CACHE_DIR="$3" SS_UNINSTALL_TEMP_DIR="$4" \
        SS_TEST_TCC_EXIT="${TCC_EXIT:-}" "$BIN" --uninstall-for-test 2>&1)"
    RC=$?
}
listing() {
    LIST="$(TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$1" SS_UNINSTALL_APP="$2" SS_UNINSTALL_CACHE_DIR="$3" SS_UNINSTALL_TEMP_DIR="$4" \
        "$BIN" --list-inventory 2>&1)"
    LRC=$?
}

make_fake_home() {
    local h="$1" l="$1/Library" e="$1/.semsearch"
    mkdir -p "$e/models/models--intfloat--multilingual-e5-small/snapshots/abc" "$e/models/.locks" \
             "$e/hf/hub" "$e/torch" "$e/st" "$e/cache" "$e/tmp" "$e/logs" \
             "$l/Preferences" "$l/Saved Application State/local.semanticspotlight.app.savedState" \
             "$l/Caches/local.semanticspotlight.app" "$l/HTTPStorages/local.semanticspotlight.app" \
             "$l/WebKit/local.semanticspotlight.app" "$l/Application Support/Semantic Spotlight" \
             "$l/Logs/Semantic Spotlight" "$l/LaunchAgents" \
             "$h/outside_target" "$h/Documents/indexed"
    head -c 1000000 /dev/zero > "$e/models/models--intfloat--multilingual-e5-small/snapshots/abc/model.safetensors"
    chmod 444 "$e/models/models--intfloat--multilingual-e5-small/snapshots/abc/model.safetensors"
    printf 'idx' > "$e/index.db"
    printf 'wal' > "$e/index.db-wal"; chmod 444 "$e/index.db-wal"
    printf 'shm' > "$e/index.db-shm"
    printf '{}' > "$e/config.json"; chmod 444 "$e/config.json"
    : > "$e/daemon.sock"
    printf 'log' > "$e/app-daemon.log"
    printf 'hub' > "$e/hf/hub/blob"
    printf 'torch' > "$e/torch/t.bin"
    printf 'st' > "$e/st/s.bin"
    printf 'cache' > "$e/cache/c.bin"
    printf 'tmp' > "$e/tmp/t.tmp"
    printf 'extra' > "$e/unknown-extra.bin"          # not in the doc, still goes: the whole folder is deleted
    printf 'old' > "$e/logs/old.log"
    printf 'lock' > "$e/models/.locks/x.lock"; chmod 555 "$e/models/.locks"
    printf 'keep' > "$h/outside_target/keep.txt"
    ln -s "$h/outside_target" "$e/linked_outside"     # a link inside the engine home: unlink, never follow
    # A real preferences file with the app's own keys: the excluded search folders and the remembered panel place.
    python3 -c 'import plistlib,sys; plistlib.dump({"searchExcludedFolders": ["/Users/someone/Documents/old"], "searchPanelPositions": {"1": [120.0, 200.0]}}, open(sys.argv[1], "wb"))' \
        "$l/Preferences/local.semanticspotlight.app.plist"
    printf 'state' > "$l/Saved Application State/local.semanticspotlight.app.savedState/data.plist"
    printf 'cache' > "$l/Caches/local.semanticspotlight.app/c.db"
    printf 'web' > "$l/HTTPStorages/local.semanticspotlight.app/h.db"
    printf 'wk' > "$l/WebKit/local.semanticspotlight.app/w.db"
    printf 'appsupport' > "$l/Application Support/Semantic Spotlight/a.json"
    printf 'log' > "$l/Logs/Semantic Spotlight/app.log"
    printf 'agent' > "$l/LaunchAgents/local.semanticspotlight.app.plist"
    mkdir -p "$l/Caches/com.example.semanticspotlight-old"   # not in the inventory: must be listed, never silently missed
    printf 'old' > "$l/Caches/com.example.semanticspotlight-old/old.db"
    chmod 555 "$l/LaunchAgents"   # a read-only parent: this file cannot be removed, and must be listed as not removed
    # The user's own data, outside the inventory. Must survive every run.
    printf 'my notes' > "$h/Documents/indexed/notes.txt"
    printf 'my photo' > "$h/Documents/keep.txt"
}

# Per-user GPU caches. The shared folder, the non-empty org.python.python and the non-folder mpsgraph file must survive.
make_gpu() { # make_gpu <cache-root> <temp-root> <keep-other: yes|no>
    local c="$1" t="$2" m="$2/com.apple.MetalPerformanceShadersGraph"
    mkdir -p "$c/org.python.python/com.apple.metal" "$c/com.apple.metal" "$m/mpsgraph-123-abc" "$m/mpsgraph-999"
    printf 'shader' > "$c/org.python.python/com.apple.metal/lib.metallib"
    printf 'shared' > "$c/com.apple.metal/shared.bin"
    # The app-keyed cache folder, and the Metal subfolders the engine creates under org.python.python.
    mkdir -p "$c/local.semanticspotlight.app/com.apple.metal" "$c/local.semanticspotlight.app/com.apple.metalfe" \
             "$c/org.python.python/com.apple.metalfe" "$c/org.python.python/com.apple.gpuarchiver"
    printf 'k' > "$c/local.semanticspotlight.app/com.apple.metal/k.metallib"
    printf 'k' > "$c/local.semanticspotlight.app/com.apple.metalfe/k"
    printf 'z' > "$c/org.python.python/com.apple.metalfe/z"
    printf 'w' > "$c/org.python.python/com.apple.gpuarchiver/w"
    printf 'g' > "$m/mpsgraph-123-abc/graph.bin"
    printf 'g' > "$m/mpsgraph-999/graph.bin"
    printf 'keep' > "$m/keepme.txt"
    printf 'file' > "$m/mpsgraph-file.txt"
    if [ "$3" = yes ]; then mkdir -p "$c/org.python.python/other"; printf 'k' > "$c/org.python.python/other/k"; fi
}

make_fake_app() {
    mkdir -p "$1/Contents/MacOS" "$1/Contents/Resources/runtime/bin"
    cp "$BIN" "$1/Contents/MacOS/SemanticSpotlight"
    printf 'fake engine' > "$1/Contents/Resources/runtime/bin/semsearch"
    chmod 444 "$1/Contents/Resources/runtime/bin/semsearch"
    printf '<plist/>' > "$1/Contents/Info.plist"
}

# The user's installed app runs against its own real home, so its own writes (the index, its log, its daemon files)
# are not the test's. The test fails only if the set of other names in the real home changed during the run.
real_home_names() {
    ls -A "$HOME/.semsearch" 2>/dev/null | grep -v -E '^(index\.db(-wal|-shm)?|app-daemon\.log|daemon\..*)$' | sort
}
REAL_NAMES="$(real_home_names)"

# --- Parity: the Swift inventory against the doc and against the expected list. ---
H="$W/home"; A="$W/app/SemanticSpotlight.app"; C="$W/darwin-cache/"; T="$W/darwin-temp/"
[ "$H" != "$HOME" ] || { echo "refusing: fake home is the real home" >&2; exit 1; }
make_fake_home "$H"; make_fake_app "$A"; make_gpu "$C" "$T" yes
EXPECT=(app "cache:local.semanticspotlight.app"
        .semsearch .semsearch/index.db .semsearch/index.db-wal .semsearch/index.db-shm .semsearch/daemon.sock
        .semsearch/models .semsearch/hf .semsearch/torch .semsearch/st .semsearch/cache .semsearch/tmp
        .semsearch/config.json .semsearch/app-daemon.log
        Library/Preferences/local.semanticspotlight.app.plist
        "Library/Saved Application State/local.semanticspotlight.app.savedState"
        Library/Caches/local.semanticspotlight.app Library/HTTPStorages/local.semanticspotlight.app
        Library/WebKit/local.semanticspotlight.app "Library/Application Support/Semantic Spotlight"
        "Library/Logs/Semantic Spotlight" Library/LaunchAgents/local.semanticspotlight.app.plist)
listing "$H" "$A" "$C" "$T"
[ "$LRC" -eq 0 ] && pass "list-inventory runs" || fail "list-inventory failed (exit $LRC)"
norm_list() { # maps "item|container <path>" lines to home-relative names (bash 3.2 cannot parse a case inside $(...))
    while read -r _kind p; do
        case "$p" in
            "$H/"*) echo "${p#$H/}" ;;
            "$A") echo app ;;
            "$C"*) echo "cache:${p#$C}" ;;
            "$T"*) echo "temp:${p#$T}" ;;
            *) echo "OTHER:$p" ;;
        esac
    done
}
GOT="$(echo "$LIST" | norm_list | sort)"
WANT="$(printf '%s\n' "${EXPECT[@]}" | sort)"
[ "$GOT" = "$WANT" ] && pass "inventory matches the expected list (${#EXPECT[@]} entries)" || { fail "inventory differs"; diff <(echo "$WANT") <(echo "$GOT") | sed 's/^/      /'; }
for n in index.db daemon.sock models hf torch st cache tmp config.json app-daemon.log; do
    grep -qF "\`$n" "$DOC" && pass "doc lists $n" || fail "doc does not list $n"
done
grep -qF "org.python.python/com.apple.metal" "$DOC" && grep -qF "com.apple.MetalPerformanceShadersGraph" "$DOC" \
    && pass "doc lists the GPU caches" || fail "doc does not list the GPU caches"
# The engine's own listing (`semsearch uninstall`, without --yes) must name the same engine-home entries as the app.
engine_names() {
    while read -r _kind p; do
        case "$p" in
            "$P/.semsearch/"*) echo "${p#$P/.semsearch/}" ;;
        esac
    done
}
P="$W/parity-home"
mkdir -p "$P/.semsearch/models" "$P/.semsearch/hf" "$P/.semsearch/torch" "$P/.semsearch/st" "$P/.semsearch/cache" "$P/.semsearch/tmp"
for n in index.db index.db-wal index.db-shm daemon.sock config.json app-daemon.log; do : > "$P/.semsearch/$n"; done
if [ -x ../.venv/bin/semsearch ]; then
    CLI_NAMES="$(HOME="$P" env -u SEMSEARCH_HOME ../.venv/bin/semsearch uninstall 2>/dev/null | sed -n 's/^  //p' | sort)"
    listing "$P" "$W/app-p/SemanticSpotlight.app" "$W/cp/" "$W/tp/"
    APP_NAMES="$(echo "$LIST" | engine_names | sort)"
    [ -n "$CLI_NAMES" ] && [ "$CLI_NAMES" = "$APP_NAMES" ] \
        && pass "engine CLI and app list the same $(echo "$CLI_NAMES" | wc -l | tr -d ' ') engine-home entries" \
        || { fail "engine CLI and app differ"; diff <(echo "$CLI_NAMES") <(echo "$APP_NAMES") | sed 's/^/      /'; }
else
    echo "skip: no dev engine at ../.venv (engine CLI parity not checked)"
fi

grep -qF "LICENSE" build.sh && grep -qF "THIRD_PARTY_NOTICES.md" build.sh && grep -qF "THIRD_PARTY_NOTICES.md" make_dmg.sh \
    && pass "build.sh and make_dmg.sh copy LICENSE and THIRD_PARTY_NOTICES.md" || fail "license copy missing from build scripts"

# --- Run 1: the full inventory, with GPU caches, a read-only tree, an inner symlink and user files. ---
printf 'crash' > "$W/tmp/SemanticSpotlight-crash.log"   # an app-named file in the temp folder, not in the inventory
TCC_EXIT=1 run "$H" "$A" "$C" "$T"   # the simulated permission reset fails, so the report must say how to finish it
echo "$OUT" | sed 's/^/      /'
[ "$RC" -eq 1 ] && pass "run 1 exit 1: the read-only item is reported, not hidden" || fail "run 1 exit $RC, expected 1"
for rel in .semsearch .semsearch/models .semsearch/unknown-extra.bin \
    Library/Preferences/local.semanticspotlight.app.plist \
    "Library/Saved Application State/local.semanticspotlight.app.savedState" \
    Library/Caches/local.semanticspotlight.app Library/HTTPStorages/local.semanticspotlight.app \
    Library/WebKit/local.semanticspotlight.app "Library/Application Support/Semantic Spotlight" \
    "Library/Logs/Semantic Spotlight"; do
    gone "$H/$rel" && pass "removed $rel" || fail "still present: $rel"
done
[ -f "$H/Library/LaunchAgents/local.semanticspotlight.app.plist" ] && pass "read-only item kept, as the report says" || fail "read-only item deleted"
[ -f "$C/org.python.python/com.apple.metal/lib.metallib" ] && [ -d "$T/com.apple.MetalPerformanceShadersGraph/mpsgraph-123-abc" ] \
    && pass "GPU: shared org.python.python and mpsgraph-* folders kept (other software uses them)" || fail "GPU: a shared folder was deleted"
[ -f "$C/com.apple.metal/shared.bin" ] && pass "GPU: shared com.apple.metal kept" || fail "shared com.apple.metal was deleted"
[ -f "$T/com.apple.MetalPerformanceShadersGraph/keepme.txt" ] && [ -f "$T/com.apple.MetalPerformanceShadersGraph/mpsgraph-file.txt" ] \
    && pass "GPU: non-mpsgraph files kept" || fail "GPU: a non-mpsgraph file was deleted"
gone "$A" && pass "app bundle removed by the helper" || { for _ in $(seq 50); do gone "$A" && break; sleep 0.2; done; }
gone "$A" && pass "app bundle removed by the helper (after wait)" || fail "app bundle still present after 10 s"
[ -z "$(ls -A "$W/tmp" | grep -v '^SemanticSpotlight-crash.log$')" ] && pass "helper script removed itself" || fail "helper left behind: $(ls "$W/tmp")"
[ "$(echo "$OUT" | grep -c '^remaining:')" -eq 1 ] && echo "$OUT" | grep -q "^remaining: $H/Library/LaunchAgents/" \
    && pass "the one remaining path is the read-only item" || fail "unexpected remaining paths"
NR="$(echo "$OUT" | grep '^notremoved: ')"
echo "$NR" | sed 's/^/      /'
has() { echo "$NR" | grep -q -F -- "$1"; }
field() { echo "$NR" | awk -F'\t' -v t="$1" 'index($1, t) {print $2; exit}'; }
# Only app-created things still present are listed. Here that is exactly the failed removal and the failed permission reset.
[ "$(echo "$NR" | grep -c '^notremoved: ')" -eq 4 ] && pass "the list holds exactly the four app items that stayed" || fail "unexpected list size"
has "Leftover named after the app" && pass "listed: app-named leftovers the inventory does not know" || fail "unknown leftovers missed"
HN="$(echo "$H" | tr -s /)"; WN="$(echo "$W" | tr -s /)"   # leftovers are listed by their standardised path
echo "$NR" | grep -q -F "$HN/Library/Caches/com.example.semanticspotlight-old" && pass "listed: the unknown library folder, by path" || fail "unknown library folder not listed"
echo "$NR" | grep -q -F "$WN/tmp/SemanticSpotlight-crash.log" && pass "listed: the unknown temp file, by path" || fail "unknown temp file not listed"
gone "$C/local.semanticspotlight.app" && pass "GPU: the app-keyed cache folder removed whole" || fail "app-keyed cache folder still present"
[ -f "$C/org.python.python/com.apple.metalfe/z" ] && [ -f "$C/org.python.python/com.apple.gpuarchiver/w" ] \
    && pass "GPU: org.python.python's Metal subfolders kept" || fail "org.python.python Metal subfolders were deleted"
has "Permission records macOS keeps for the app" && pass "listed: the permission records (reset failed here, on purpose)" || fail "missing: permission records"
[ "$(field "Could not remove")" = "$H/Library/LaunchAgents/local.semanticspotlight.app.plist" ] \
    && pass "listed: the read-only item, with its path" || fail "missing: read-only item"
has "Folders and files you indexed" && fail "user folders listed" || pass "not listed: your indexed folders"
has "Metal cache" && fail "shared Metal cache listed" || pass "not listed: the shared Metal cache"
has "Interpreter cache" && fail "interpreter cache listed" || pass "not listed: org.python.python (not app-created)"
has "Diagnostics or uninstall report" && fail "user report listed" || pass "not listed: user-created report files"
has "SemanticSpotlight.dmg" && fail "user disk image listed" || pass "not listed: the disk image"
has "Trash" && fail "Trash fallback listed without cause" || pass "not listed: the Trash (the helper did not run here)"
echo "$OUT" | grep -q "Documents\|my photo\|keep.txt" && fail "a user file was named in the output" || pass "user files are not named anywhere in the output"
echo "$OUT" | grep -q "^summary: Some things the app created are still present" && pass "summary says something is left" || fail "summary wrong"
echo "$NR" | grep -q "chmod u+w" && pass "every failure has a command that finishes it" || fail "no command for the failure"
# Every path in the list must still exist after the run, and nothing listed may have been deleted.
while IFS=$'\t' read -r _t listed _why _cmd; do
    case "$listed" in
        /*) [ -e "$listed" ] && pass "listed and still there: $listed" || fail "listed but gone: $listed" ;;
    esac
done <<< "$NR"
[ "$(cat "$H/outside_target/keep.txt" 2>/dev/null)" = "keep" ] && pass "symlink target outside the folder untouched" || fail "symlink target was damaged"
[ "$(cat "$H/Documents/keep.txt" 2>/dev/null)" = "my photo" ] && pass "user file outside the inventory untouched" || fail "user file was damaged"
[ "$(cat "$H/Documents/indexed/notes.txt" 2>/dev/null)" = "my notes" ] && pass "indexed-folder file untouched" || fail "indexed-folder file was damaged"

rm -f "$W/tmp/SemanticSpotlight-crash.log"   # the test's own fixture: the next run must find nothing app-named

# --- Run 2: ~/.semsearch is itself a symlink; the link goes, the folder behind it stays. The shared
#     org.python.python folder stays even when it would be empty: it belongs to other software. ---
H2="$W/home2"; A2="$W/app2/SemanticSpotlight.app"; C2="$W/darwin-cache2/"; T2="$W/darwin-temp2/"
mkdir -p "$H2/elsewhere" "$H2/Documents"; printf 'keep' > "$H2/elsewhere/keep.txt"; printf 'mine' > "$H2/Documents/mine.txt"
ln -s "$H2/elsewhere" "$H2/.semsearch"; make_fake_app "$A2"
mkdir -p "$C2/org.python.python/com.apple.metal" "$C2/org.python.python/com.apple.metalfe" "$C2/org.python.python/com.apple.gpuarchiver" "$T2"
printf 'shader' > "$C2/org.python.python/com.apple.metal/lib.metallib"; printf 'x' > "$C2/org.python.python/com.apple.metalfe/x"; printf 'x' > "$C2/org.python.python/com.apple.gpuarchiver/x"
run "$H2" "$A2" "$C2" "$T2"
[ "$RC" -eq 0 ] && pass "run 2 exit 0" || fail "run 2 exit $RC"
[ -z "$(echo "$OUT" | grep '^notremoved: ')" ] && pass "run 2: the Not removed list is empty when everything was removable" || fail "run 2: list not empty"
echo "$OUT" | grep -q "^summary: Everything the app created was removed. Your own files and the folders you indexed were left alone.$" \
    && pass "run 2: the summary says everything the app created was removed" || fail "run 2: summary sentence missing"
gone "$H2/.semsearch" && pass "symlinked ~/.semsearch removed (the link)" || fail "symlink still present"
[ "$(cat "$H2/elsewhere/keep.txt" 2>/dev/null)" = "keep" ] && pass "folder behind the link untouched" || fail "link target was deleted"
[ "$(cat "$H2/Documents/mine.txt" 2>/dev/null)" = "mine" ] && pass "user file untouched (run 2)" || fail "user file damaged (run 2)"
[ -f "$C2/org.python.python/com.apple.metal/lib.metallib" ] && pass "GPU: shared org.python.python kept (run 2)" || fail "GPU: shared org.python.python deleted (run 2)"
gone "$A2" && pass "run 2 app bundle removed" || { for _ in $(seq 50); do gone "$A2" && break; sleep 0.2; done; gone "$A2" && pass "run 2 app bundle removed (after wait)" || fail "run 2 app bundle present"; }

# --- Run 3: refused app path. The home folder must never be deleted as "the app". ---
H3="$W/home3"; make_fake_home "$H3"
run "$H3" "$H3" "$W/darwin-cache3/" "$W/darwin-temp3/"
[ "$RC" -eq 1 ] && pass "run 3 exit 1 (refusal reported)" || fail "run 3 exit $RC, expected 1"
echo "$OUT" | grep -q "not an expected location" && pass "refusal message shown" || fail "no refusal message"
[ -d "$H3" ] && [ "$(cat "$H3/Documents/keep.txt" 2>/dev/null)" = "my photo" ] && pass "home folder and user files intact" || fail "home folder damaged"

# --- Run 4: a root home must refuse everything, including the GPU caches. ---
C4="$W/darwin-cache4/"; T4="$W/darwin-temp4/"; make_gpu "$C4" "$T4" no
run "/" "$W/app4/SemanticSpotlight.app" "$C4" "$T4"
[ -d /Applications ] && [ -d /Library ] && pass "run 4 (home=/): system folders intact" || fail "system folders damaged"
[ -f "$C4/com.apple.metal/shared.bin" ] && [ -f "$C4/org.python.python/com.apple.metal/lib.metallib" ] \
    && pass "run 4 (home=/): GPU caches refused and kept" || fail "run 4 (home=/): GPU caches were deleted"

[ "$(real_home_names)" = "$REAL_NAMES" ] && pass "real ~/.semsearch untouched (no new or removed entries)" || fail "real ~/.semsearch changed"

echo
if [ "$FAILS" -eq 0 ]; then echo "uninstall check: PASS"; else echo "uninstall check: $FAILS failure(s)"; fi
exit "$FAILS"
