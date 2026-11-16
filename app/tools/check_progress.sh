#!/usr/bin/env bash
# Acceptance test for the indexing progress row and the polling rate (the menu-bar icon is static). A stub engine
# (tools/fake_engine.py) answers status from a state file with made-up numbers, in a fake HOME. The app logs
# its progress row and icon timer to stderr in test mode; the test waits for those lines and samples the app.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh

swift build >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build --show-bin-path)/SemanticSpotlight"
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-prog.XXXXXX")"
tl_init "$W"
mkdir -p "$W/tmp" "$W/home/Documents" "$W/app/SemanticSpotlight.app/Contents/MacOS"
cp "$BIN" "$W/app/SemanticSpotlight.app/Contents/MacOS/SemanticSpotlight"
cp Resources/Info.plist "$W/app/SemanticSpotlight.app/Contents/Info.plist"
APP="$W/app/SemanticSpotlight.app"
STATE="$W/state.json"; REQS="$W/requests.log"; ERR="$W/app.err"
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }

# One folder, so the welcome window stays closed and polling uses the busy and idle rates.
FOLDERS="[\"$W/home/Documents\"]"
set_state() { printf '%s\n' "${1//FOLDERS/$FOLDERS}" > "$STATE"; }
count() { grep -c -F -- "$1" "$ERR" 2>/dev/null || true; }
requests() { wc -l < "$REQS" | tr -d ' '; }
wait_log() { # wait_log <text> <seconds>: true once the text is in the app's log
    local i
    for i in $(seq $(( $2 * 10 ))); do [ "$(count "$1")" -ge 1 ] && return 0; sleep 0.1; done
    return 1
}

set_state '{"files": 26, "chunks": 130, "folders": FOLDERS, "indexing": false, "progress": {"phase": "idle", "done": 0, "total": 0}}'
touch "$REQS"
python3 tools/fake_engine.py "$W/home" "$STATE" "$REQS" &
tl_track "$!"
for _ in $(seq 50); do [ -S "$W/home/.semsearch/daemon.sock" ] && break; sleep 0.1; done

launch() { # launch [extra env assignments...]
    env CFFIXED_USER_HOME="$W/home" HOME="$W/home" TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$W/home" SS_UNINSTALL_APP="$APP" \
        SS_UNINSTALL_CACHE_DIR="$W/c/" SS_UNINSTALL_TEMP_DIR="$W/t/" "$@" \
        "$APP/Contents/MacOS/SemanticSpotlight" 2> "$ERR" &
    APP_PID=$!
    tl_track "$APP_PID"
}

launch
wait_log 'progress hidden' 8

# --- A. Idle: no icon timer, the progress row hidden, and polling about every 5 s. ---
kill -0 "$APP_PID" 2>/dev/null && pass "app running against the stub engine" || fail "app not running: $(tail -2 "$ERR")"
[ "$(count "progress hidden")" -ge 1 ] && pass "idle: progress row hidden" || fail "idle: progress row not hidden"
sleep 1; R0="$(requests)"; sleep 6; R1="$(requests)"
[ "$((R1 - R0))" -le 2 ] && pass "idle: polls about every 5 s ($((R1 - R0)) in 6 s)" || fail "idle: $((R1 - R0)) polls in 6 s"

# --- B. Scanning: indeterminate bar, the looking-for-changes line, icon timer on, polls about every 0.5 s. ---
set_state '{"files": 26, "chunks": 130, "folders": FOLDERS, "indexing": true, "progress": {"phase": "scanning", "done": 0, "total": 0}}'
wait_log 'progress indeterminate "Looking for changes…"' 8 && pass "scanning: indeterminate bar, \"Looking for changes…\"" || fail "scanning: wrong progress row"
sleep 1; R0="$(requests)"; sleep 3; R1="$(requests)"
[ "$((R1 - R0))" -ge 4 ] && [ "$((R1 - R0))" -le 8 ] && pass "scanning: polls about every 0.5 s ($((R1 - R0)) in 3 s)" || fail "scanning: $((R1 - R0)) polls in 3 s"

# --- C. Indexing: determinate bar with the count, and the main thread idle between frames. ---
set_state '{"files": 120, "chunks": 500, "folders": FOLDERS, "indexing": true, "progress": {"phase": "indexing", "done": 120, "total": 300}}'
wait_log 'progress determinate 120/300 "Indexing 120 of 300 files"' 5 && pass "indexing: \"Indexing 120 of 300 files\", determinate" || fail "indexing: wrong progress row"
# The main thread is idle between frames when the app as a whole stays nearly idle while busy. Average the CPU over
# the busy window, and take three samples as evidence (printed; a single sample is too noisy to decide on).
CPU_SUM=0; alert=0
for n in 1 2 3 4 5 6; do
    CPU_SUM=$(python3 -c "print($CPU_SUM + $(ps -o %cpu= -p "$APP_PID" | tr -d ' ' | sed 's/^$/0/'))")
    if [ "$n" -le 3 ]; then
        sample "$APP_PID" 1 -file "$W/sample-indexing-$n.txt" >/dev/null 2>&1
        MAIN="$(awk '/Thread_[0-9]+ .*(com.apple.main-thread|Main Thread)/ {on=1; print; next} on && /Thread_[0-9]+/ {on=0} on' "$W/sample-indexing-$n.txt" 2>/dev/null)"
        echo "      sample $n: main thread leaf-in-run-loop: $(echo "$MAIN" | grep -c 'mach_msg2_trap') frames, alert frames: $(echo "$MAIN" | grep -c -E 'NSAlert|runModal')"
        echo "$MAIN" | grep -q -E "NSAlert|runModal" && alert=$((alert + 1))
    fi
    sleep 0.5
done
AVG_CPU=$(python3 -c "print(round($CPU_SUM / 6, 1))")
python3 -c "import sys; sys.exit(0 if $AVG_CPU < 10 else 1)" && pass "indexing: average CPU $AVG_CPU% over the busy window: the main thread is idle between frames" || fail "indexing: CPU $AVG_CPU% while busy"
[ "$alert" -eq 0 ] && pass "indexing: no alert on the main thread in any sample" || fail "indexing: an alert is on the main thread"

# --- D. Done: the timer stops, the bar hides, polling slows back down. ---
set_state '{"files": 300, "chunks": 1300, "folders": FOLDERS, "indexing": false, "progress": {"phase": "idle", "done": 0, "total": 0}}'
[ "$(count "progress hidden")" -ge 2 ] && pass "done: progress row hidden again" || fail "done: progress row still shown"
sleep 6; R0="$(requests)"; sleep 6; R1="$(requests)"
[ "$((R1 - R0))" -le 2 ] && pass "done: back to about every 5 s ($((R1 - R0)) in 6 s)" || fail "done: $((R1 - R0)) polls in 6 s"

# --- E. An older engine: no progress field, only the indexing flag. The bar is indeterminate, "Indexing…". ---
set_state '{"files": 26, "chunks": 130, "folders": FOLDERS, "indexing": true}'
wait_log 'progress indeterminate "Indexing…"' 8 && pass "older engine: indeterminate bar, \"Indexing…\"" || fail "older engine: wrong progress row"
set_state '{"files": 26, "chunks": 130, "folders": FOLDERS, "indexing": false}'

kill -TERM "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
kill -TERM "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null
if [ "$FAILS" -eq 0 ]; then echo; echo "progress check: PASS"; else echo; echo "progress check: $FAILS failure(s)"; fi
exit "$FAILS"
