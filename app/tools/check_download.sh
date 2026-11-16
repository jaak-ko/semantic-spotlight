#!/usr/bin/env bash
# The model download, against a fake fetch script (tools/fake_fetch.py), headless: the eased bar over a bursty stream,
# cancel from downloading and from retrying (SIGTERM; SIGKILL for a child that ignores it), no zombie, resume, and the
# Cancel button in the welcome block and in Settings. The test runs in its own launch (--download-test-for-test).
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh

swift build >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build --show-bin-path)/SemanticSpotlight"
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-download-check.XXXXXX")"
tl_init "$W"
mkdir -p "$W/tmp" "$W/home" "$W/c" "$W/t" "$W/app/SemanticSpotlight.app/Contents/MacOS"
cp "$BIN" "$W/app/SemanticSpotlight.app/Contents/MacOS/SemanticSpotlight"
cp Resources/Info.plist "$W/app/SemanticSpotlight.app/Contents/Info.plist"
APP="$W/app/SemanticSpotlight.app"
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }

ERR="$W/download.err"
env SS_HEADLESS=1 HOME="$W/home" CFFIXED_USER_HOME="$W/home" TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$W/home" SS_UNINSTALL_APP="$APP" \
    SS_UNINSTALL_CACHE_DIR="$W/c/" SS_UNINSTALL_TEMP_DIR="$W/t/" \
    "$APP/Contents/MacOS/SemanticSpotlight" --download-test-for-test 2> "$ERR" &
PID=$!
tl_track "$PID"
for _ in $(seq 1200); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$PID" 2>/dev/null; then fail "still running after 120 s"; kill -KILL "$PID"; wait "$PID" 2>/dev/null; else wait "$PID"; fi

grep "download test" "$ERR" | sed 's/^\[test\] /      /' | grep -v ": ok" | head -20
[ "$(grep -c "download test: ok" "$ERR")" -ge 10 ] && pass "$(grep -c "download test: ok" "$ERR") download checks pass" || fail "too few download checks ran"
grep -q "download test: done, 0 failures" "$ERR" && pass "the download test finished with no failures" || fail "the download test failed"
grep -q "download test: FAIL" "$ERR" && fail "a download check failed (see above)"
if [ "$FAILS" -eq 0 ]; then echo; echo "download check: PASS"; else echo; echo "download check: $FAILS failure(s)"; fi
exit "$FAILS"
