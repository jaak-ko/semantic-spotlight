#!/usr/bin/env bash
# Headless checks on the real windows (welcome and Settings): the traffic-light buttons are visible, enabled where they
# should be, hit at their centres (not a SwiftUI view), close when pressed; the top strip drags the window.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh

swift build >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build --show-bin-path)/SemanticSpotlight"
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-chrome-check.XXXXXX")"
tl_init "$W"
mkdir -p "$W/tmp" "$W/home" "$W/app/SemanticSpotlight.app/Contents/MacOS"
cp "$BIN" "$W/app/SemanticSpotlight.app/Contents/MacOS/SemanticSpotlight"
cp Resources/Info.plist "$W/app/SemanticSpotlight.app/Contents/Info.plist"
APP="$W/app/SemanticSpotlight.app"
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }
env HOME="$W/home" CFFIXED_USER_HOME="$W/home" TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$W/home" SS_UNINSTALL_APP="$APP" \
    SS_UNINSTALL_CACHE_DIR="$W/c/" SS_UNINSTALL_TEMP_DIR="$W/t/" "$APP/Contents/MacOS/SemanticSpotlight" --chrome-test-for-test 2> "$W/chrome.err" &
pid=$!
tl_track "$pid"
for _ in $(seq 600); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
wait "$pid"
grep "chrome test" "$W/chrome.err" | sed 's/^\[test\] /      /'
grep -q "chrome test: done, 0 failure(s)" "$W/chrome.err" && pass "traffic lights visible, enabled and clickable; top strip drags; close works (welcome and Settings)" || fail "a window chrome check failed"
if [ "$FAILS" -eq 0 ]; then echo; echo "chrome check: PASS"; else echo; echo "chrome check: $FAILS failure(s)"; fi
exit "$FAILS"
