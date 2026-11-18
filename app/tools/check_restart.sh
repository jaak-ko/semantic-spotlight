#!/usr/bin/env bash
# The engine's memory restart: the daemon exits with code 75 right after an index request (fake engine, in a fake HOME).
# The app must relaunch it for any exit, say why in its log, send index again so the run continues, not loop, and never
# ask for status faster than every 0.5 s. Fake HOME only; the stub engine stands in for semsearch.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh

swift build >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build --show-bin-path)/SemanticSpotlight"
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-restart-test.XXXXXX")"
tl_init "$W"
APP="$W/app/SemanticSpotlight.app"
mkdir -p "$W/tmp" "$W/c/" "$W/t/" "$APP/Contents/MacOS" "$W/eng/.venv/bin" "$W/home/.semsearch"
cp "$BIN" "$APP/Contents/MacOS/SemanticSpotlight"
cp Resources/Info.plist "$APP/Contents/Info.plist"
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }

# The stub engine: `semsearch daemon` runs the fake engine on this home, with a state that exits 75 once on index.
FAKE="$(pwd)/tools/fake_engine.py"
STATE="$W/state.json"; REQS="$W/requests.log"
cat > "$W/eng/.venv/bin/semsearch" <<SH
#!/bin/bash
exec /usr/bin/python3 -B "$FAKE" "\$HOME" "$STATE" "$REQS"
SH
chmod +x "$W/eng/.venv/bin/semsearch"
cat > "$STATE" <<'JSON'
{"files": 40, "chunks": 90, "folders": ["/fixture/small", "/fixture/large"], "indexing": true, "model_ready": true,
 "exit_on_index": 75,
 "progress": {"phase": "indexing", "done": 30, "total": 200, "waiting_cloud": 0,
              "folders": [{"path": "/fixture/small", "phase": "done", "done": 10, "total": 10},
                          {"path": "/fixture/large", "phase": "indexing", "done": 20, "total": 190}]}}
JSON
A="$W/home"
LOG="$A/.semsearch/app-daemon.log"

env HOME="$A" CFFIXED_USER_HOME="$A" TMPDIR="$W/tmp" SS_ENGINE_PATH="$W/eng" \
    SS_UNINSTALL_HOME="$A" SS_UNINSTALL_APP="$APP" SS_UNINSTALL_CACHE_DIR="$W/c/" SS_UNINSTALL_TEMP_DIR="$W/t/" \
    "$APP/Contents/MacOS/SemanticSpotlight" --show-diagnostics-for-test 2> "$W/app.err" &
tl_track "$!"
waitfor() { for _ in $(seq $(( $2 * 2 ))); do /usr/bin/grep -q -- "$1" "$LOG" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
count_index() { /usr/bin/grep -c '^index$' "$REQS" 2>/dev/null || true; }

waitfor "app: engine exited (exit code 75)" 20 && pass "the exit with code 75 is recorded" || fail "no exit 75 line: $(tail -3 "$LOG" 2>/dev/null)"
waitfor "app: starting engine (reason: restart after exit code 75)" 20 && pass "the app relaunches the engine for code 75, with the reason" \
    || fail "no restart for 75"
sleep 6   # time for the restarted engine to answer, and for any loop to show
[ "$(/usr/bin/grep -c 'engine exited' "$LOG")" -eq 1 ] && pass "one exit only: no restart loop" || fail "exits: $(/usr/bin/grep -c 'engine exited' "$LOG")"
[ "$(/usr/bin/grep -c 'app: starting engine' "$LOG")" -eq 2 ] && pass "two starts: the launch and the restart" || fail "starts: $(/usr/bin/grep -c 'app: starting engine' "$LOG")"
[ "$(count_index)" -eq 2 ] && pass "index sent again after the restart, so the run continues" || fail "index requests: $(count_index)"
if /usr/bin/grep -qiE 'engine failed|not found|error' "$W/app.err" 2>/dev/null; then fail "an error reached the app's stderr"; else pass "no user-visible error"; fi

# Poll rate: the status times the stub logged (numeric lines) are at least 0.45 s apart.
gap=$(/usr/bin/grep -E '^[0-9.]+$' "$REQS" | python3 -c 'import sys; t=[float(x) for x in sys.stdin.read().split()]; print(min((b-a for a,b in zip(t,t[1:])), default=99))')
python3 -c "import sys; sys.exit(0 if float('$gap') >= 0.45 else 1)" && pass "status polls at least 0.45 s apart (smallest gap $gap s)" \
    || fail "status polled $gap s apart"

if [ "$FAILS" -eq 0 ]; then echo; echo "restart check: PASS"; else echo; echo "restart check: $FAILS failure(s)"; fi
exit "$FAILS"
