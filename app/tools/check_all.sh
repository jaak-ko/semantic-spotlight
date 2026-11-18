#!/usr/bin/env bash
# Runs every check script, then the clean-state guard after each one. Stops nothing early: every check runs.
cd "$(dirname "$0")/.."
FAILED=""
# Whether the real engine home existed before the run: checked after every script (see check_clean_state.sh).
if [ -e "$HOME/.semsearch" ]; then export SS_REAL_HOME_BASELINE=yes; else export SS_REAL_HOME_BASELINE=no; fi
if [ -e "$HOME/Library/Preferences/local.semanticspotlight.app.plist" ]; then export SS_REAL_PREFS_BASELINE=yes; else export SS_REAL_PREFS_BASELINE=no; fi
# The user's real engine home must not change during the run (names, sizes, times only; see semsearch_home_guard.py).
SNAP="$(mktemp "${TMPDIR:-/tmp}/semhome-snap.XXXXXX")"
python3 tools/semsearch_home_guard.py snap "$SNAP"
# A user's app may start during the run: this samples for it until the end (its marker is read by compare).
python3 tools/semsearch_home_guard.py watch "$SNAP" &
WATCH_PID=$!
for t in check_redaction check_uninstall check_uninstall_sheet check_diagnostics check_progress check_menu_stress check_search_scope check_onboarding check_layout check_folders check_theme check_chrome check_download check_log check_restart; do
    echo "=================== $t"
    if ! bash "tools/$t.sh"; then FAILED="$FAILED $t"; fi
    echo "--- clean state after $t"
    bash tools/check_clean_state.sh || FAILED="$FAILED clean-after-$t"
done
echo
if ! python3 tools/semsearch_home_guard.py compare "$SNAP"; then FAILED="$FAILED real-engine-home"; fi
kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null
rm -f "$SNAP" "$SNAP.seen"
if [ -z "$FAILED" ]; then echo "all checks: PASS"; else echo "all checks: FAILED:$FAILED"; fi
[ -z "$FAILED" ]
