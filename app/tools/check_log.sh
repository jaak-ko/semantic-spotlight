#!/usr/bin/env bash
# The app's own log (app-daemon.log) is kept across starts: each line has a local time; the app's lines say when the engine
# starts and why, and each exit with its code or signal. It rotates at 512 KB and keeps four files, all 0600.
# Run A (fresh home): the folder is 0700, the file 0600, the first line is the launch; a killed engine is recorded as
# an exit, and the restart says why. Run B: a 2 MB log from an earlier run is rotated to .1 when the app starts.
# Fake HOMEs only; the dev engine (.venv) runs under them.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh

swift build >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build --show-bin-path)/SemanticSpotlight"
ENGINE="$(cd .. && pwd)/.venv/bin/semsearch"
[ -x "$ENGINE" ] || { echo "FAIL: no dev engine at $ENGINE" >&2; exit 1; }
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-log-test.XXXXXX")"
tl_init "$W"
APP="$W/app/SemanticSpotlight.app"
mkdir -p "$W/tmp" "$W/c/" "$W/t/" "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SemanticSpotlight"
cp Resources/Info.plist "$APP/Contents/Info.plist"
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }
size() { stat -f %z "$1" 2>/dev/null || echo 0; }
mode() { stat -f %Lp "$1" 2>/dev/null || echo none; }

start_app() { # start_app <fake home>: the app with the dev engine, as the diagnostics check starts it
    env HOME="$1" CFFIXED_USER_HOME="$1" TMPDIR="$W/tmp" SS_ENGINE_PATH="$(cd .. && pwd)" \
        SS_UNINSTALL_HOME="$1" SS_UNINSTALL_APP="$APP" SS_UNINSTALL_CACHE_DIR="$W/c/" SS_UNINSTALL_TEMP_DIR="$W/t/" \
        "$APP/Contents/MacOS/SemanticSpotlight" --show-diagnostics-for-test 2> "$W/app.err" &
    tl_track "$!"
}
wait_socket() { # wait_socket <fake home>: until the daemon listens (it starts after the log is opened)
    for _ in $(seq 60); do [ -S "$1/.semsearch/daemon.sock" ] && return 0; sleep 0.5; done
    return 1
}

# Run A: fresh home. The folder and file modes, the launch line, then an engine killed by a signal is recorded and restarted.
A="$W/fresh"; mkdir -p "$A"
start_app "$A"; APP_PID=$!
wait_socket "$A" || fail "run A: the daemon never came up"
LOG="$A/.semsearch/app-daemon.log"
[ "$(mode "$A/.semsearch")" = 700 ] && pass "a new log folder is 0700" || fail "log folder mode $(mode "$A/.semsearch")"
[ "$(mode "$LOG")" = 600 ] && pass "the log file is 0600" || fail "log file mode $(mode "$LOG")"
/usr/bin/grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} app: starting engine \(reason: launch\)$' "$LOG" \
    && pass "the first line is the launch, with a local time" || fail "no launch line: $(head -2 "$LOG")"
ENG="$(pgrep -P "$APP_PID" | head -1 || true)"
if [ -n "$ENG" ]; then
    kill -9 "$ENG" 2>/dev/null
    for _ in $(seq 40); do /usr/bin/grep -q "app: engine exited (signal 9)" "$LOG" && break; sleep 0.5; done
    /usr/bin/grep -qE 'app: engine exited \(signal 9\)$' "$LOG" && pass "a killed engine is recorded with its signal" || fail "no exit line"
    for _ in $(seq 40); do /usr/bin/grep -q "reason: restart after signal 9" "$LOG" && break; sleep 0.5; done
    /usr/bin/grep -q "app: starting engine (reason: restart after signal 9)" "$LOG" && pass "the restart says why" || fail "no restart reason"
else
    fail "run A: no engine process to kill"
fi

# Run B: a 2 MB log from an earlier run is rotated to .1 when the app starts; the new log is small and 0600.
B="$W/big"; mkdir -p "$B/.semsearch"
head -c 2000000 /dev/zero | tr '\0' 'x' > "$B/.semsearch/app-daemon.log"
start_app "$B"
wait_socket "$B" || fail "run B: the daemon never came up"
[ -f "$B/.semsearch/app-daemon.log.1" ] && [ "$(size "$B/.semsearch/app-daemon.log.1")" -ge 2000000 ] \
    && pass "the 2 MB log is kept as .1" || fail "run B: no rotated copy"
[ "$(size "$B/.semsearch/app-daemon.log")" -lt 524288 ] && [ "$(mode "$B/.semsearch/app-daemon.log")" = 600 ] \
    && pass "the new log is under 512 KB and 0600" || fail "run B: new log $(size "$B/.semsearch/app-daemon.log") bytes, mode $(mode "$B/.semsearch/app-daemon.log")"

if [ "$FAILS" -eq 0 ]; then echo; echo "log check: PASS"; else echo; echo "log check: $FAILS failure(s)"; fi
exit "$FAILS"
