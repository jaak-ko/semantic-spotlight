#!/usr/bin/env bash
# Headless checks for the search panel's folder scope, its folder list, its place and dragging (ScopeTests.swift).
# Nothing is shown on the desktop: the panel and its list are transparent, and the test drives them directly.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh

swift build >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build --show-bin-path)/SemanticSpotlight"
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-scope-check.XXXXXX")"
tl_init "$W"
mkdir -p "$W/tmp" "$W/home/Documents" "$W/app/SemanticSpotlight.app/Contents/MacOS"
cp "$BIN" "$W/app/SemanticSpotlight.app/Contents/MacOS/SemanticSpotlight"
cp Resources/Info.plist "$W/app/SemanticSpotlight.app/Contents/Info.plist"
APP="$W/app/SemanticSpotlight.app"
ERR="$W/scope.err"
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }

env CFFIXED_USER_HOME="$W/home" HOME="$W/home" TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$W/home" SS_UNINSTALL_APP="$APP" \
    SS_UNINSTALL_CACHE_DIR="$W/c/" SS_UNINSTALL_TEMP_DIR="$W/t/" \
    "$APP/Contents/MacOS/SemanticSpotlight" --scope-test-for-test 2> "$ERR" &
PID=$!
tl_track "$PID"
for _ in $(seq 600); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
wait "$PID"; RC=$?
grep -q "scope test: done" "$ERR" && pass "the scope run finished and the app quit itself (exit $RC)" || fail "the scope run did not finish (exit $RC)"
grep -q "scope test: done, [0-9]* checks, 0 failures" "$ERR" && pass "$(grep -o '[0-9]* checks, 0 failures' "$ERR" | tail -1)" \
    || fail "some scope checks failed"
grep "scope test: FAIL" "$ERR" | sed 's/^/      /'
grep -q "scope test: ok the list was made once in this run" "$ERR" && pass "the folder list is created once for all hovers and clicks" \
    || fail "the folder list was created more than once"
grep -qi "already is in another menu\|uncaught exception" "$ERR" && fail "an AppKit exception" || pass "no AppKit exception"

if [ "$FAILS" -eq 0 ]; then echo; echo "search scope check: PASS"; else echo; echo "search scope check: $FAILS failure(s)"; fi
exit "$FAILS"
