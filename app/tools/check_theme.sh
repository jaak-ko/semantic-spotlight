#!/usr/bin/env bash
# Headless checks for the brand look: the contrast of every token pair the surfaces use (light and dark, WCAG AA), the
# offscreen renders of every surface and state (SHOTS_OUT keeps them), and the menu-bar logo assigned once and unchanged.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh

swift build >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build --show-bin-path)/SemanticSpotlight"
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-theme-check.XXXXXX")"
tl_init "$W"
mkdir -p "$W/tmp" "$W/home" "$W/shots" "$W/app/SemanticSpotlight.app/Contents/MacOS"
cp "$BIN" "$W/app/SemanticSpotlight.app/Contents/MacOS/SemanticSpotlight"
cp Resources/Info.plist "$W/app/SemanticSpotlight.app/Contents/Info.plist"
APP="$W/app/SemanticSpotlight.app"
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }
run() { # run <name> <args...>
    local name="$1"; shift
    env HOME="$W/home" CFFIXED_USER_HOME="$W/home" TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$W/home" SS_UNINSTALL_APP="$APP" \
        SS_UNINSTALL_CACHE_DIR="$W/c/" SS_UNINSTALL_TEMP_DIR="$W/t/" "$APP/Contents/MacOS/SemanticSpotlight" "$@" 2> "$W/$name.err" &
    local pid=$!
    tl_track "$pid"
    for _ in $(seq 600); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    wait "$pid"
}
run theme --theme-test-for-test "$W/shots"
grep "theme contrast" "$W/theme.err" | sed 's/^\[test\] /      /'
grep "glass contrast" "$W/theme.err" | sed 's/^\[test\] /      /'
grep "theme: success" "$W/theme.err" | sed 's/^\[test\] /      /'
grep "theme test: done\|FAIL\|button scan\|menu test" "$W/theme.err" | grep -v "^ok" | sed 's/^\[test\] /      /' | head -12
grep -q "theme test: done, 0 failures" "$W/theme.err" && pass "every token pair meets its contrast minimum (light and dark)" || fail "a contrast or render check failed"
[ "$(ls "$W/shots" | wc -l | tr -d ' ')" -ge 18 ] && pass "$(ls "$W/shots" | wc -l | tr -d ' ') surface renders written (light and dark)" || fail "missing surface renders"
run icon --menu-icon-test-for-test
grep "menu icon:" "$W/icon.err" | sed 's/^\[test\] /      /' | tail -3
grep -q "menu icon: ok the logo is assigned once" "$W/icon.err" && pass "the menu-bar logo is assigned once and identical in every state" || fail "the menu-bar logo changed"
if [ -n "${SHOTS_OUT:-}" ]; then mkdir -p "$SHOTS_OUT" && cp "$W/shots/"*.png "$SHOTS_OUT/"; fi
if [ "$FAILS" -eq 0 ]; then echo; echo "theme check: PASS"; else echo; echo "theme check: $FAILS failure(s)"; fi
exit "$FAILS"
