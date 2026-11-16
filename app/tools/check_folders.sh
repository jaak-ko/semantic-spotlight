#!/usr/bin/env bash
# Headless checks for adding a folder while the engine starts, fails, or lacks its model (FoldersTests.swift). The
# scripted run needs no socket; the socket runs use the production EngineManager against tools/fake_engine.py (up, then
# absent). Nothing touches the network or the real engine.
set -uo pipefail
cd "$(dirname "$0")/.."
. tools/testlib.sh

swift build >/dev/null || { echo "build failed" >&2; exit 1; }
BIN="$(swift build --show-bin-path)/SemanticSpotlight"
W="$(mktemp -d "${TMPDIR:-/tmp}/ss-folders-check.XXXXXX")"
tl_init "$W"
mkdir -p "$W/tmp" "$W/home" "$W/engine/.venv/bin" "$W/app/SemanticSpotlight.app/Contents/MacOS"
cp "$BIN" "$W/app/SemanticSpotlight.app/Contents/MacOS/SemanticSpotlight"
cp Resources/Info.plist "$W/app/SemanticSpotlight.app/Contents/Info.plist"
cp tools/fake_fetch.py "$W/engine/.venv/bin/semsearch" && chmod +x "$W/engine/.venv/bin/semsearch"
APP="$W/app/SemanticSpotlight.app"
FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
pass() { echo "ok:   $*"; }
run_app() { # run_app <env assignment...>: runs the test binary, waits, and reports its end line
    local name="$1"; local err="$W/$name.err"; shift
    env HOME="$W/home" CFFIXED_USER_HOME="$W/home" TMPDIR="$W/tmp" SS_UNINSTALL_HOME="$W/home" SS_UNINSTALL_APP="$APP" \
        SS_UNINSTALL_CACHE_DIR="$W/c/" SS_UNINSTALL_TEMP_DIR="$W/t/" SS_ENGINE_PATH="$W/engine" "$@" \
        "$APP/Contents/MacOS/SemanticSpotlight" --folders-test-for-test 2> "$err" &
    local pid=$!
    tl_track "$pid"
    for _ in $(seq 600); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    wait "$pid"; RC=$?
    grep "folders test:" "$err" | sed 's/^\[test\] /      /'
    grep -q "folders test: done, [0-9]* checks, 0 failures" "$err" && pass "$name: $(grep -o '[0-9]* checks, 0 failures' "$err" | tail -1) (exit $RC)" \
        || fail "$name: checks failed or the run did not finish (exit $RC)"
}

# 1. Scripted engine: starting, never appearing, Retry, model missing, engine error.
run_app scripted

# 2. The real socket, with tools/fake_engine.py up. One path is refused for its model.
STATE="$W/engine-state.json"
printf '{"files": 0, "chunks": 0, "folders": [], "indexing": false, "model": "m", "model_ready": true, "add_errors": {"/tmp/fake/socket-model": "model intfloat/multilingual-e5-small is not installed; run `semsearch fetch-model`"}}\n' > "$STATE"
python3 tools/fake_engine.py "$W/home" "$STATE" "$W/requests.log" &
FAKE=$!
tl_track "$FAKE"
for _ in $(seq 50); do [ -S "$W/home/.semsearch/daemon.sock" ] && break; sleep 0.1; done
run_app socket-present FOLDERS_SOCKET_TEST=present
kill -TERM "$FAKE" 2>/dev/null; wait "$FAKE" 2>/dev/null
rm -f "$W/home/.semsearch/daemon.sock"

# 3. No engine at all: the socket is missing, so the cause is "not running".
run_app socket-absent FOLDERS_SOCKET_TEST=absent

if [ "$FAILS" -eq 0 ]; then echo; echo "folders check: PASS"; else echo; echo "folders check: $FAILS failure(s)"; fi
exit "$FAILS"
