#!/usr/bin/env bash
# Acceptance test for Copy/Save diagnostics and the uninstall report, against fake HOMEs only.
#  A. A real engine (the dev .venv) in a fake HOME with a cloned model, an indexed folder whose names contain
#     spaces and ä/ö, and a realistic daemon log (paths, quotes, e-mails, query and snippet lines).
#  B. The uninstall report from a second fake HOME, after the test-only confirm.
# The clipboard and save destinations are injected files; no panel, no pasteboard, no Desktop. The real HOME is only
# fingerprinted (read-only) and the real models are only cloned with cp -c.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh

swift build >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build --show-bin-path)/SemanticSpotlight"
ENGINE="$(cd .. && pwd)/.venv/bin/semsearch"
REAL="$HOME/.semsearch"
PREFS="$HOME/Library/Preferences/local.semanticspotlight.app.plist"
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-diag-test.XXXXXX")"
tl_init "$W"
mkdir -p "$W/tmp" "$W/out"
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }
req() { python3 "$(dirname "$0")/req_socket.py" "$@"; }
# The real home's entries, minus the names the app and its engine create themselves (they change while the user's app
# runs), and the prefs mtime, which only counts while no user app runs (the guard in semsearch_home_guard.py decides).
fingerprint() {
    echo "$(ls -A "$REAL" 2>/dev/null | grep -v -E '^(index\.db(-wal|-shm)?|app-daemon\.log|daemon\..*|daemon\.sock|cache|hf|st|torch|tmp|models|config\.json)$' | sort | tr '\n' ' ')"
}
user_app_now() { python3 "$(cd "$(dirname "$0")" && pwd)/semsearch_home_guard.py" running "$REAL/.none" 2>/dev/null; }
prefs_mtime() { stat -f '%m' "$PREFS" 2>/dev/null || echo none; }
REAL_PREFS_BEFORE="$(prefs_mtime)"; REAL_USER_APP_BEFORE="$(user_app_now)"
REAL_BEFORE="$(fingerprint)"
DESKTOP_BEFORE="$(ls "$HOME/Desktop" 2>/dev/null | grep -c 'SemanticSpotlight-' || true)"
[ -x "$ENGINE" ] || { echo "FAIL: no dev engine at $ENGINE" >&2; exit 1; }

# The real model is cloned read-only (cp -c) when this machine has one. Without it, the model-dependent lines are
# not checked, and the rest of the test still runs.
MODEL_SRC=""
for cand in "$REAL/models/models--intfloat--multilingual-e5-small" "$HOME/.cache/huggingface/hub/models--intfloat--multilingual-e5-small"; do
    [ -d "$cand/snapshots" ] && { MODEL_SRC="$cand"; break; }
done
[ -n "$MODEL_SRC" ] || echo "skip: no e5 model on this machine; the model and folder lines are not checked"

make_home() { # make_home <fake home>: config, cloned model, folders with awkward names, and the realistic log
    local h="$1"
    mkdir -p "$h/.semsearch" "$h/Documents/Ääkkönen työ" "$h/Documents/My Notes" "$h/Documents/projects/notes 2026"
    printf '{"model": "intfloat/multilingual-e5-small", "ocr_languages": ["fi-FI", "sv-SE", "en-US"], "min_similarity": 0.81, "engine_path": "%s"}\n' "$(cd .. && pwd)" > "$h/.semsearch/config.json"
    if [ -n "$MODEL_SRC" ]; then
        mkdir -p "$h/.semsearch/models"
        cp -cR "$MODEL_SRC" "$h/.semsearch/models/"   # APFS clone: no bytes copied
    fi
    printf 'budget 2025 secret plan for the sauna project\n' > "$h/Documents/Ääkkönen työ/raportti öljy.txt"
    printf 'lasagna notes, very private\n' > "$h/Documents/My Notes/secret plan.txt"
    printf 'quarterly numbers\n' > "$h/Documents/projects/notes 2026/Kesäkuu.txt"
    cat > "$h/.semsearch/app-daemon.log" <<'LOG'
2026-11-14 12:00:01 warning: skipping __HOME__/Documents/Ääkkönen työ/raportti öljy.txt: rtf conversion failed (ValueError)
2026-11-14 12:00:02 skip __HOME__/Documents/Ääkkönen työ/kuva öö.png: image larger than max_image_bytes
2026-11-14 12:00:03 skip "__HOME__/Documents/My Notes/secret plan.txt": OCR failed (no text)
2026-11-14 12:00:04 warning: could not read __HOME__/Documents/projects/notes 2026/Kesäkuu.txt: Permission denied
2026-11-14 12:00:05 skip /Users/testuser/Documents/elsewhere/Matkalippu.pdf: symlink resolves outside /Users/testuser/Documents
2026-11-14 12:00:06 query "budget 2025 testuser@example.com" returned 8 results
2026-11-14 12:00:07 snippet: Discussed the Q2 budget with Ana
2026-11-14 12:00:08 mail someone@example.org failed to sync
2026-11-14 12:00:09 index settings changed (abc123): rebuilding index
LOG
    sed -i '' "s|__HOME__|$h|g" "$h/.semsearch/app-daemon.log"
    # The engine's event log: hostile messages (a path and an e-mail inside a field) that the report must redact.
    cat > "$h/.semsearch/events.jsonl" <<'EVENTS'
{"ts":"2026-11-13T09:15:00+02:00","level":"info","event":"daemon_start","run":"3f9a1c2b","version":"0.1.0"}
{"ts":"2026-11-13T09:16:00+02:00","level":"warn","event":"index_error","run":"3f9a1c2b","class":"OSError","message":"could not read __HOME__/Documents/My Notes/secret plan.txt for someone@example.org"}
{"ts":"2026-11-13T09:17:00+02:00","level":"info","event":"index_end","run":"3f9a1c2b","files":26,"chunks":130,"seconds":4}
{"ts":"2026-11-14T08:00:00+02:00","level":"info","event":"daemon_stop","run":"3f9a1c2b"}
{"ts":"2026-11-14T08:00:05+02:00","level":"warn","event":"search_slow","run":"5b2d7e90","ms":2400,"folders":2}
EVENTS
    sed -i '' "s|__HOME__|$h|g" "$h/.semsearch/events.jsonl"
}

# --- A. Diagnostics from a real engine. ---
HA="$W/home-a"; APPA="$W/a/SemanticSpotlight.app"
make_home "$HA"
# The cloned model carries no verified marker (the real install's marker is not copied). The CLI's status checks an
# installed model offline and synchronously once, which writes the marker in this fixture: the fixture is migrated first.
env CFFIXED_USER_HOME="$HA" HOME="$HA" "$ENGINE" status --json > "$W/fixture-status.json" 2>&1 || true
mkdir -p "$APPA/Contents/MacOS"; cp "$BIN" "$APPA/Contents/MacOS/SemanticSpotlight"; cp Resources/Info.plist "$APPA/Contents/Info.plist"
# Register the folder with a daemon first, so the app's engine starts with it.
env CFFIXED_USER_HOME="$HA" HOME="$HA" "$ENGINE" daemon > "$W/daemon-a.out" 2>&1 &
DPID=$!
tl_track "$DPID"
for _ in $(seq 120); do [ -S "$HA/.semsearch/daemon.sock" ] && break; sleep 0.5; done
# The daemon checks an installed model on its worker thread at start. Wait (bounded, 20 s) until that check is over and the
# model is ready, so the app reads a settled status.
for i in $(seq 40); do
    st="$(req "$HA" '{"cmd":"status"}' 2>/dev/null || true)"
    if echo "$st" | /usr/bin/grep -q '"model_verifying": false' && echo "$st" | /usr/bin/grep -q '"model_ready": true'; then
        echo "daemon settled after about $(( i / 2 )) s"; break
    fi
    [ "$i" = 40 ] && echo "daemon not settled after 20 s: $(echo "$st" | head -c 200)"
    sleep 0.5
done
if [ -n "$MODEL_SRC" ]; then
    req "$HA" '{"cmd":"add","path":"'"$HA"'/Documents"}' > /dev/null
    for _ in $(seq 120); do req "$HA" '{"cmd":"status"}' | /usr/bin/grep -q '"indexing": false' && break; sleep 0.5; done
fi
kill -TERM "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
for _ in $(seq 20); do [ -S "$HA/.semsearch/daemon.sock" ] || break; sleep 0.5; done

env CFFIXED_USER_HOME="$HA" HOME="$HA" SS_ENGINE_PATH="$(cd .. && pwd)" TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$HA" SS_UNINSTALL_APP="$APPA" \
    SS_UNINSTALL_CACHE_DIR="$W/cache-a/" SS_UNINSTALL_TEMP_DIR="$W/temp-a/" \
    SS_TEST_CLIPBOARD_FILE="$W/out/clipboard-a.txt" SS_TEST_SAVE_PATH="$W/out/diagnostics.txt" \
    SS_TEST_AUTOCOPY=1 SS_TEST_AUTOSAVE=1 \
    "$APPA/Contents/MacOS/SemanticSpotlight" --show-diagnostics-for-test > "$W/app-a.out" 2>&1 &
PA=$!
tl_track "$PA"
for _ in $(seq 120); do [ -s "$W/out/diagnostics.txt" ] && [ -s "$W/out/clipboard-a.txt" ] && break; sleep 0.5; done
sleep 1
kill -0 "$PA" 2>/dev/null && pass "app running (pid $PA) with the diagnostics sheet" || fail "app exited: $(tail -2 "$W/app-a.out")"
if tl_idle_sample "$PA" "$W/sample-a" > "$W/idle-a.path"; then IDLE_A=ok; else IDLE_A=layout; fi
MAINA="$(awk '/com.apple.main-thread|Main Thread/ {on=1; print; next} on && /Thread_[0-9]+/ {on=0} on' "$(cat "$W/idle-a.path")")"
if echo "$MAINA" | /usr/bin/grep -q "CFRunLoop"; then pass "main thread idle in the run loop"
else fail "main thread not idle (its top frames below)"; echo "$MAINA" | head -12 | sed 's/^/      /'; fi
if echo "$MAINA" | /usr/bin/grep -q -E "NSAlert|NSISEngine|updateConstraintsForSubtreeIfNeeded"; then
    fail "main thread in layout (sample frames below)"; echo "$MAINA" | /usr/bin/grep -E "NSAlert|NSISEngine|updateConstraints" | head -6 | sed 's/^/      /'
else pass "main thread not in alert or constraint layout"; fi

OUT="$W/out/diagnostics.txt"
if [ -s "$OUT" ]; then
    pass "diagnostics saved only after the test save action"
    [ "$(stat -f '%Lp' "$OUT")" = "600" ] && pass "saved file has mode 0600" || fail "mode is $(stat -f '%Lp' "$OUT")"
    cmp -s "$OUT" "$W/out/clipboard-a.txt" && pass "copied text is identical to the saved text" || fail "copy and save differ"
    echo "----- redacted diagnostics (as saved) -----"; sed 's/^/| /' "$OUT"; echo "-------------------------------------------"
    MODEL_LINES=(); [ -n "$MODEL_SRC" ] && MODEL_LINES=("Model installed: yes" "folders: 1")
    for want in "Engine: running" ${MODEL_LINES[@]+"${MODEL_LINES[@]}"} "Config model: intfloat/multilingual-e5-small" \
                "Config ocr_languages: fi-FI, sv-SE, en-US" "Config min_similarity: 0.81" "Login item: " "Hotkey: " \
                "~/…/<file>.txt" "/…/<file>.pdf" "\"<text>\"" "<email>" "[line omitted: may contain a query or file content]" \
                "Recent events (" "warn index_error class=OSError" "Activity by day" "starts 1 (unclean 0)" "App log (last"; do
        /usr/bin/grep -qF -- "$want" "$OUT" && pass "shows: $want" || fail "missing: $want"
    done
    if ! /usr/bin/grep -qF -- "Engine: running" "$OUT"; then   # the app's view of the engine did not settle: its own logs
        echo "----- app output (engine not running) -----"; tail -6 "$W/app-a.out" | cut -c1-200 | sed 's/^/| /'
        echo "----- test daemon output -----"; tail -4 "$W/daemon-a.out" | cut -c1-200 | sed 's/^/| /'
    fi
    for secret in "testuser" "someone" "example.com" "Documents" "Ääkkönen" "työ" "öljy" "raportti" "kuva" "Kesäkuu" \
                  "projects" "My Notes" "secret plan" "budget" "Ana" "sauna" "lasagna" "quarterly" "notes 2026" "/Users/" "var/folders" \
                  "Matkalippu" "elsewhere" "__HOME__"; do
        /usr/bin/grep -qF -- "$secret" "$OUT" && fail "leaked: $secret" || pass "no $secret"
    done
else
    fail "no diagnostics file was saved"
fi
[ -z "$(ls -A "$W/tmp" | /usr/bin/grep -i -E 'diagnos|report|semsearch-' || true)" ] && pass "no diagnostics temp files left behind" || fail "temp file left: $(ls "$W/tmp")"
kill -TERM "$PA" 2>/dev/null; sleep 1
pkill -TERM -P "$PA" 2>/dev/null
sleep 1

# --- B. The uninstall report, from a fake HOME, with the test-only confirm. ---
HB="$W/home-b"; APPB="$W/b/SemanticSpotlight.app"
make_home "$HB"
mkdir -p "$HB/Library/Preferences" "$HB/Library/Caches/local.semanticspotlight.app" "$HB/Library/LaunchAgents"
printf 'plist' > "$HB/Library/Preferences/local.semanticspotlight.app.plist"
printf 'cache' > "$HB/Library/Caches/local.semanticspotlight.app/c.db"
printf 'agent' > "$HB/Library/LaunchAgents/local.semanticspotlight.app.plist"
chmod 555 "$HB/Library/Caches"   # one removal must fail, so the report shows the "could not remove" path too
mkdir -p "$APPB/Contents/MacOS"; cp "$BIN" "$APPB/Contents/MacOS/SemanticSpotlight"; cp Resources/Info.plist "$APPB/Contents/Info.plist"
DOCS_BEFORE="$(cd "$HB" && find . -type f | sort)"
env CFFIXED_USER_HOME="$HB" HOME="$HB" TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$HB" SS_UNINSTALL_APP="$APPB" \
    SS_UNINSTALL_CACHE_DIR="$W/cache-b/" SS_UNINSTALL_TEMP_DIR="$W/temp-b/" \
    SS_UNINSTALL_AUTOCONFIRM=1 SS_TEST_REPORT_CAP=3 SS_TEST_CLIPBOARD_FILE="$W/out/clipboard-b.txt" SS_TEST_SAVE_PATH="$W/out/report.txt" \
    SS_TEST_AUTOCOPY=1 SS_TEST_AUTOSAVE=1 \
    "$APPB/Contents/MacOS/SemanticSpotlight" --show-uninstall-for-test > "$W/app-b.out" 2>&1 &
PB=$!
tl_track "$PB"
for _ in $(seq 60); do [ -s "$W/out/report.txt" ] && [ -s "$W/out/clipboard-b.txt" ] && break; sleep 0.5; done
sleep 1
if tl_idle_sample "$PB" "$W/sample-b" > "$W/idle-b.path"; then IDLE_B=ok; else IDLE_B=layout; fi
MAINB="$(awk '/com.apple.main-thread|Main Thread/ {on=1; print; next} on && /Thread_[0-9]+/ {on=0} on' "$(cat "$W/idle-b.path")")"
[ "$IDLE_B" = ok ] && pass "main thread answers after uninstall (idle in a sample)" || fail "main thread stuck after uninstall: layout in every sample"
REP="$W/out/report.txt"
if [ -s "$REP" ]; then
    [ "$(stat -f '%Lp' "$REP")" = "600" ] && pass "report file has mode 0600" || fail "report mode is $(stat -f '%Lp' "$REP")"
    cmp -s "$REP" "$W/out/clipboard-b.txt" && pass "copied report is identical to the saved report" || fail "report copy and save differ"
    echo "----- redacted uninstall report (as saved) -----"; sed 's/^/| /' "$REP"; echo "-------------------------------------------------"
    /usr/bin/grep -q "Removed (" "$REP" && pass "lists what was removed" || fail "no removed list"
    /usr/bin/grep -q "App bundle:" "$REP" && pass "states the app-bundle result" || fail "no app-bundle line"
    /usr/bin/grep -q "Could not remove (1):" "$REP" && /usr/bin/grep -q "permission" "$REP" \
        && pass "lists the item that could not be removed, with the reason" || fail "no could-not-remove section"
    /usr/bin/grep -q "Still present (1):" "$REP" && pass "lists what is still present" || fail "no still-present section"
    /usr/bin/grep -q "^Not removed (" "$REP" && /usr/bin/grep -q "to finish: chmod u+w" "$REP" \
        && pass "the report has the Not removed block, with how to finish each item" || fail "no Not removed block"
    /usr/bin/grep -q "^  … and [0-9]* more$" "$REP" && /usr/bin/grep -q "^Removed ([0-9]*):$" "$REP" \
        && pass "a long list is cut at the cap, and its count is kept" || fail "list not cut at the cap"
    [ "$(sed -n '/^Removed (/,/^$/p' "$REP" | grep -c '^  ')" -le 4 ] && pass "the removed list shows at most the cap plus the 'more' line" || fail "removed list longer than the cap"
    /usr/bin/grep -q "Your own files and the folders you indexed were left alone." "$REP" \
        && pass "the report says the user's own files were left alone" || fail "no user-files sentence"
    /usr/bin/grep -q "Folders and files you indexed\|Diagnostics or uninstall report" "$REP" \
        && fail "the report lists user-created items" || pass "the report lists no user-created items"
    for secret in "$HB" "$W" "var/folders" "testuser" "Documents" "Library" "Ääkkönen" "secret"; do
        /usr/bin/grep -qF -- "$secret" "$REP" && fail "report leaked: $secret" || pass "report has no $secret"
    done
else
    fail "no report was saved"
fi
kill -TERM "$PB" 2>/dev/null; sleep 3
# Nothing is left behind: the removed items are gone, and the only files still in the fake HOME are the user's documents.
[ ! -e "$HB/.semsearch" ] && [ ! -e "$HB/Library/Preferences/local.semanticspotlight.app.plist" ] && pass "uninstall removed the fake HOME items" || fail "items remain"
# The read-only Caches folder blocks removing its item: the file inside goes, the folder stays, and the report says so.
LEFT="$(cd "$HB" && find . -type f | sort | /usr/bin/grep -v '^./Documents/' || true)"
[ -z "$LEFT" ] && [ -d "$HB/Library/Caches/local.semanticspotlight.app" ] \
    && pass "only the folder that could not be removed is left, and the report lists it" || fail "left behind: $LEFT"
[ "$(cd "$HB" && find . -type f | sort)" = "$(echo "$DOCS_BEFORE" | /usr/bin/grep '^./Documents/')" ] && pass "user documents unchanged" || fail "documents changed"
[ -z "$(ls -A "$W/tmp" | /usr/bin/grep -i -E 'diagnos|report|uninstall' || true)" ] && pass "no report or log written to temp" || fail "temp file left: $(ls "$W/tmp")"

# --- Real data: unchanged. ---
# Unchanged, and the prefs too unless a user app ran at either end (its own writes are not the test's).
REAL_NOW_USER_APP="$(user_app_now)"
if [ "$(fingerprint)" = "$REAL_BEFORE" ] && { [ "$REAL_USER_APP_BEFORE" = yes ] || [ "$REAL_NOW_USER_APP" = yes ] || [ "$(prefs_mtime)" = "$REAL_PREFS_BEFORE" ]; }; then pass "real ~/.semsearch and prefs unchanged"; else fail "real data changed: $REAL_BEFORE -> $(fingerprint)"; fi
[ "$(ls "$HOME/Desktop" 2>/dev/null | grep -c 'SemanticSpotlight-' || true)" = "$DESKTOP_BEFORE" ] && pass "nothing written to the real Desktop" || fail "Desktop changed"

if [ "$FAILS" -eq 0 ]; then echo; echo "diagnostics check: PASS"; else echo; echo "diagnostics check: $FAILS failure(s)"; fi
exit "$FAILS"
