#!/usr/bin/env bash
# Headless checks for the welcome window's download states (OnboardingTests.swift). The engine is tools/fake_fetch.py,
# given to the app as SS_ENGINE_PATH; nothing touches the network or the real engine. The step-1 card is rendered to PNG.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh

swift build >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build --show-bin-path)/SemanticSpotlight"
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-onboarding-check.XXXXXX")"
tl_init "$W"
mkdir -p "$W/tmp" "$W/home" "$W/shots" "$W/engine/.venv/bin" "$W/app/SemanticSpotlight.app/Contents/MacOS"
cp "$BIN" "$W/app/SemanticSpotlight.app/Contents/MacOS/SemanticSpotlight"
cp Resources/Info.plist "$W/app/SemanticSpotlight.app/Contents/Info.plist"
cp tools/fake_fetch.py "$W/engine/.venv/bin/semsearch" && chmod +x "$W/engine/.venv/bin/semsearch"
APP="$W/app/SemanticSpotlight.app"
ERR="$W/onboarding.err"
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }

env HOME="$W/home" CFFIXED_USER_HOME="$W/home" TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$W/home" SS_UNINSTALL_APP="$APP" \
    SS_UNINSTALL_CACHE_DIR="$W/c/" SS_UNINSTALL_TEMP_DIR="$W/t/" SS_ENGINE_PATH="$W/engine" SS_DUMP_DIR="$W/shots" \
    "$APP/Contents/MacOS/SemanticSpotlight" --onboarding-test-for-test 2> "$ERR" &
PID=$!
tl_track "$PID"
for _ in $(seq 600); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
wait "$PID"; RC=$?
grep -q "onboarding test: done" "$ERR" && pass "the run finished and the app quit itself (exit $RC)" || fail "the run did not finish (exit $RC)"
grep "onboarding test:" "$ERR" | sed 's/^\[test\] /      /'
grep -q "onboarding test: done, [0-9]* checks, 0 failures" "$ERR" && pass "$(grep -o '[0-9]* checks, 0 failures' "$ERR" | tail -1)" || fail "some checks failed"
[ -s "$W/shots/onboarding-failed-collapsed.png" ] && pass "step-1 card rendered (collapsed and expanded)" || fail "no rendered card"
# Optional: keep the rendered cards (SHOTS_OUT=<folder>).
if [ -n "${SHOTS_OUT:-}" ]; then mkdir -p "$SHOTS_OUT" && cp "$W/shots/"*.png "$SHOTS_OUT/" 2>/dev/null; fi

if [ "$FAILS" -eq 0 ]; then echo; echo "onboarding check: PASS"; else echo; echo "onboarding check: $FAILS failure(s)"; fi
exit "$FAILS"
