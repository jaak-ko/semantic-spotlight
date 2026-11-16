#!/usr/bin/env bash
# Guard, run after every check script (tools/check_all.sh does this). Fails if a test left anything behind:
#  - an engine daemon still listening in a test temp directory (ss-* under TMPDIR), found by its socket (lsof -U),
#    because this macOS does not show another process's HOME. Daemons of other work (not under ss-*) are not counted;
#  - a SemanticSpotlight.dmg, or a test disk image, still mounted or attached;
#  - an ss-* temp directory still there.
set -uo pipefail
T="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
TL="${T#/private}"   # lsof and mount name the path without /private
bad=0

# The user's real engine home must not appear during a build or a check. check_all records whether it existed when
# the run began (SS_REAL_HOME_BASELINE=yes|no); a run that finds it newly created fails here.
if [ -e "$HOME/.semsearch" ] && [ "${SS_REAL_HOME_BASELINE:-no}" != "yes" ]; then
    echo "left: the real engine home $HOME/.semsearch was created during this run (no check or build may create it)"
    bad=1
fi
# No check or dump may create the app's real defaults domain. check_all records whether it existed when the run began
# (SS_REAL_PREFS_BASELINE=yes|no), as for the engine home; the installed app's own plist is never removed here.
PREFS="$HOME/Library/Preferences/local.semanticspotlight.app.plist"
if [ -e "$PREFS" ] && [ "${SS_REAL_PREFS_BASELINE:-no}" != "yes" ]; then
    echo "left: the real defaults domain local.semanticspotlight.app was created during this run ($PREFS); no test may write it"
    bad=1
fi

while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "left: engine daemon still running: $line"; bad=1
done < <(lsof -U 2>/dev/null | awk -v d="$TL/ss-" 'index($0, d) {print $2}' | sort -u | while read -r pid; do
    echo "$pid $(ps -o command= -p "$pid" 2>/dev/null)"
done)

if hdiutil info 2>/dev/null | grep -q -F -e "SemanticSpotlight.dmg" -e "$TL/ss-"; then
    echo "left: a SemanticSpotlight disk image is still attached or mounted:"
    hdiutil info | grep -F -e "SemanticSpotlight.dmg" -e "$TL/ss-" | sed 's/^/      /'
    bad=1
fi
if mount | grep -q -F -e "SemanticSpotlight" -e " on $TL/ss-"; then
    echo "left: a mount for SemanticSpotlight is still there:"; mount | grep -F -e "SemanticSpotlight" -e " on $TL/ss-" | sed 's/^/      /'
    bad=1
fi

for d in "$T"/ss-*; do
    [ -e "$d" ] || continue
    echo "left: temp directory $d"; bad=1
done

if [ "$bad" -eq 0 ]; then echo "clean state: no engine daemon, no mounted image, no ss-* temp directory"
else echo "clean state: FAILED" >&2; fi
exit "$bad"
