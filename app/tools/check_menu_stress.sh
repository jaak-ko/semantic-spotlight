#!/usr/bin/env bash
# Stress test for the status menu. The app drives StatusMenu with random engine states (some through a background
# queue hop) and opens and closes the menu for real, changing the state while it is tracking. The test passes when
# every seed runs to the end (a menu crash would kill the app) and no rebuild happens while the menu is open.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh

swift build >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build --show-bin-path)/SemanticSpotlight"
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-menu-stress.XXXXXX")"
tl_init "$W"
mkdir -p "$W/tmp" "$W/home" "$W/app/SemanticSpotlight.app/Contents/MacOS"
cp "$BIN" "$W/app/SemanticSpotlight.app/Contents/MacOS/SemanticSpotlight"
cp Resources/Info.plist "$W/app/SemanticSpotlight.app/Contents/Info.plist"
APP="$W/app/SemanticSpotlight.app"
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }

for seed in 1 2 3; do
    ERR="$W/app-$seed.err"
    env CFFIXED_USER_HOME="$W/home" HOME="$W/home" TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$W/home" SS_UNINSTALL_APP="$APP" \
        SS_UNINSTALL_CACHE_DIR="$W/c/" SS_UNINSTALL_TEMP_DIR="$W/t/" SS_TEST_SEED="$seed" \
        "$APP/Contents/MacOS/SemanticSpotlight" --stress-menu-for-test 300 2> "$ERR" &
    PID=$!
    tl_track "$PID"
    for _ in $(seq 1200); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$PID" 2>/dev/null; then fail "seed $seed: still running after 120 s"; kill -KILL "$PID"; wait "$PID" 2>/dev/null; continue; fi
    wait "$PID"; RC=$?
    grep -q "menu stress: done, 300 steps" "$ERR" && pass "seed $seed: all 300 steps ran, the app quit itself (exit $RC)" \
        || fail "seed $seed: the run did not finish (exit $RC): $(tail -1 "$ERR" | cut -c1-160)"
    grep -q "rebuilt while open in 0$" "$ERR" && pass "seed $seed: no rebuild while the menu was open ($(grep -o 'tracking steps [0-9]*' "$ERR" | tail -1))" \
        || fail "seed $seed: a rebuild happened while the menu was open"
    grep -qi "already is in another menu\|uncaught exception" "$ERR" && fail "seed $seed: an AppKit menu exception" || pass "seed $seed: no AppKit menu exception"
    REBUILDS="$(grep -o 'done, 300 steps, [0-9]* rebuilds' "$ERR" | grep -o '[0-9]*' | tail -1)"
    [ "${REBUILDS:-0}" -ge 100 ] && pass "seed $seed: $REBUILDS rebuilds (hundreds of structural changes, many while the folders submenu was open)" \
        || fail "seed $seed: too few rebuilds ($REBUILDS)"
    grep -q "menu stress: items made [0-9]*, reused 0, misattached 0" "$ERR" \
        && pass "seed $seed: every submenu and item was new when made; none reused, none attached to the wrong menu" \
        || fail "seed $seed: an item was reused or attached to the wrong menu"
done

# Counter: 200 progress ticks must rebuild the menu 0 times, create no status item (headless);
# one structural change must rebuild it exactly once.
CERR="$W/counter.err"
env CFFIXED_USER_HOME="$W/home" HOME="$W/home" TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$W/home" SS_UNINSTALL_APP="$APP" \
    SS_UNINSTALL_CACHE_DIR="$W/c/" SS_UNINSTALL_TEMP_DIR="$W/t/" \
    "$APP/Contents/MacOS/SemanticSpotlight" --headless-counter-for-test 200 2> "$CERR" &
PID=$!
tl_track "$PID"
for _ in $(seq 600); do kill -0 "$PID" 2>/dev/null || break; sleep 0.1; done
wait "$PID"; RC=$?
grep "counter:" "$CERR" | sed 's/^/      /'
for want in "All ready" "1 failed to add" "1 with no supported files" "Indexing 1 of 3" "1 failed to add · Indexing 1 of 2" "none yet"; do
    grep -qxF "[test] summary: $want" "$CERR" && pass "summary: \"$want\"" || fail "summary wrong: expected \"$want\""
done
grep -q "status items created 0, menu attachments 0, rebuilds during ticks 0, items made during ticks 0" "$CERR" \
    && pass "counter: 200 progress ticks with the menu and submenu open: 0 rebuilds, 0 items made, 0 status items created" \
    || fail "counter: progress ticks changed the menu or the counts are wrong (exit $RC)"
grep -q "one structural change while open: rebuilds while open 0, rebuilds after close 1" "$CERR" \
    && pass "counter: a structural change waits for the close, then rebuilds once" \
    || fail "counter: a structural change was not deferred to the close, or rebuilt more than once"
grep -q "counter: items made [0-9]*, reused 0, misattached 0" "$CERR" && pass "counter: no item reused or misattached" \
    || fail "counter: an item was reused or attached to the wrong menu"

if [ "$FAILS" -eq 0 ]; then echo; echo "menu stress check: PASS"; else echo; echo "menu stress check: $FAILS failure(s)"; fi
exit "$FAILS"
