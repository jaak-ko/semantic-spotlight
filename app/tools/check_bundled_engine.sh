#!/usr/bin/env bash
# Fails unless the engine bundled in the app is the repo's engine: the same files, ignoring __pycache__. A stale runtime
# once shipped an older engine. build.sh and make_dmg.sh both run this. Usage: tools/check_bundled_engine.sh <App.app>
set -euo pipefail
APP="$1"
ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
BUNDLED="$APP/Contents/Resources/runtime/python/lib/python3.12/site-packages/semsearch"
if [ ! -d "$APP/Contents/Resources/runtime" ]; then echo "bundled engine: none (development build)"; exit 0; fi
[ -d "$BUNDLED" ] || { echo "error: no bundled semsearch at $BUNDLED" >&2; exit 1; }
if ! diff -r -x __pycache__ "$BUNDLED" "$ROOT/engine/semsearch" >/dev/null; then
    echo "error: the bundled engine differs from engine/semsearch (run engine/package_runtime.sh, then build again):" >&2
    diff -rq -x __pycache__ "$BUNDLED" "$ROOT/engine/semsearch" | head -10 >&2
    exit 1
fi
echo "bundled engine matches engine/semsearch"
