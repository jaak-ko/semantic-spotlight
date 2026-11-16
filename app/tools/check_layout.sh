#!/usr/bin/env bash
# Headless layout checks for the search panel (LayoutTests.swift): the header is pinned, the panel height follows the
# results, the list scrolls only past its cap, and the popover, a drag and selection leave the header alone.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh

swift build >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build --show-bin-path)/SemanticSpotlight"
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-layout-check.XXXXXX")"
tl_init "$W"
mkdir -p "$W/tmp" "$W/home" "$W/shots" "$W/app/SemanticSpotlight.app/Contents/MacOS"
cp "$BIN" "$W/app/SemanticSpotlight.app/Contents/MacOS/SemanticSpotlight"
cp Resources/Info.plist "$W/app/SemanticSpotlight.app/Contents/Info.plist"
APP="$W/app/SemanticSpotlight.app"
ERR="$W/layout.err"
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }

env HOME="$W/home" CFFIXED_USER_HOME="$W/home" TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$W/home" SS_UNINSTALL_APP="$APP" \
    SS_UNINSTALL_CACHE_DIR="$W/c/" SS_UNINSTALL_TEMP_DIR="$W/t/" SS_DUMP_DIR="$W/shots" \
    "$APP/Contents/MacOS/SemanticSpotlight" --layout-test-for-test 2> "$ERR" &
PID=$!
tl_track "$PID"
for _ in $(seq 600); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
wait "$PID"; RC=$?
grep -q "layout test: done" "$ERR" && pass "the run finished and the app quit itself (exit $RC)" || fail "the run did not finish (exit $RC)"
grep "layout frames:" "$ERR" | sed 's/^\[test\] layout frames: /      /'
grep "layout test: FAIL" "$ERR" | sed 's/^\[test\] /      /'
grep -q "layout test: done, [0-9]* checks, 0 failures" "$ERR" && pass "$(grep -o '[0-9]* checks, 0 failures' "$ERR" | tail -1)" || fail "some layout checks failed"
if [ -n "${SHOTS_OUT:-}" ]; then mkdir -p "$SHOTS_OUT" && cp "$W/shots/"*.png "$SHOTS_OUT/" 2>/dev/null; fi
if [ "$FAILS" -eq 0 ]; then echo; echo "layout check: PASS"; else echo; echo "layout check: $FAILS failure(s)"; fi
exit "$FAILS"
