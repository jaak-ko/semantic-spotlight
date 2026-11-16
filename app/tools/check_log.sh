#!/usr/bin/env bash
# The daemon log stays under 1 MB. Run A (fresh home): the folder is created 0700 and the file 0600; the log grown past
# the cap while the daemon runs is trimmed by the status poll (at most once a minute). Run B: a 2 MB log is trimmed
# when the daemon starts. Fake HOMEs only; the dev engine (.venv) runs under them.
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

# Run A: fresh home, log grown past the cap while the daemon runs.
A="$W/fresh"; mkdir -p "$A"
start_app "$A"
wait_socket "$A" || fail "run A: the daemon never came up"
LOG="$A/.semsearch/app-daemon.log"
[ "$(mode "$A/.semsearch")" = 700 ] && pass "a new log folder is 0700" || fail "log folder mode $(mode "$A/.semsearch")"
[ "$(mode "$LOG")" = 600 ] && pass "the log file is 0600" || fail "log file mode $(mode "$LOG")"
head -c 1500000 /dev/zero | tr '\0' 'y' >> "$LOG"   # the daemon keeps writing; here the log jumps past the cap
for _ in $(seq 45); do [ "$(size "$LOG")" -lt 1000000 ] && break; sleep 2; done   # the check runs at most once a minute
[ "$(size "$LOG")" -lt 1000000 ] && pass "a log past 1 MB is trimmed while the daemon runs" || fail "log still $(size "$LOG") bytes"
[ "$(mode "$LOG")" = 600 ] && pass "the trimmed log keeps mode 0600" || fail "mode after trim $(mode "$LOG")"

# Run B: a 2 MB log from an earlier run is trimmed when the daemon starts, and kept (not deleted).
B="$W/big"; mkdir -p "$B/.semsearch"
head -c 2000000 /dev/zero | tr '\0' 'x' > "$B/.semsearch/app-daemon.log"
start_app "$B"
wait_socket "$B" || fail "run B: the daemon never came up"
[ -f "$B/.semsearch/app-daemon.log" ] && [ "$(size "$B/.semsearch/app-daemon.log")" -lt 1000000 ] \
    && pass "a 2 MB log is trimmed when the daemon starts" || fail "run B: log $(size "$B/.semsearch/app-daemon.log") bytes"

if [ "$FAILS" -eq 0 ]; then echo; echo "log check: PASS"; else echo; echo "log check: $FAILS failure(s)"; fi
exit "$FAILS"
