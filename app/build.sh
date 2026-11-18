#!/usr/bin/env bash
# Builds Semantic Spotlight with SwiftPM, assembles dist/SemanticSpotlight.app with the
# engine runtime inside (when present), ad-hoc signs it, and makes dist/SemanticSpotlight.dmg.
# No Developer ID, no notarization. Fails loudly on any error.
#
# Env overrides:
#   SS_RUNTIME_SRC  runtime folder to bundle (default: ../engine/dist/runtime)
#   SS_SKIP_DMG=1   build the .app only
set -euo pipefail

cd "$(dirname "$0")"
PROJECT_ROOT="$(cd .. && pwd)"
BUILD_SHA="$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null)" ]; then BUILD_SHA="$BUILD_SHA-dirty"; fi
# A copy that is running from dist/ (the user may be using it) is never replaced: the new build goes to a folder of its own.
if pgrep -f "$PWD/dist/SemanticSpotlight.app/Contents/MacOS/SemanticSpotlight" >/dev/null 2>&1; then
    OUT="dist/staging-$BUILD_SHA"
    echo "note: a copy is running from dist/; building into $OUT and leaving dist/ alone" >&2
else
    OUT="dist"
fi
APP="$OUT/SemanticSpotlight.app"
RUNTIME_SRC="${SS_RUNTIME_SRC:-$PROJECT_ROOT/engine/dist/runtime}"

# Map this checkout to /src in debug info and #file strings, so the shipped app carries no build path or username.
# Only Sources/ is mapped: mapping all of $PWD also rewrites the Clang module cache under .build and breaks it.
echo "==> swift build -c release"
swift build -c release -Xswiftc -file-prefix-map -Xswiftc "$PWD/Sources=/src/Sources" -Xswiftc -debug-prefix-map -Xswiftc "$PWD/Sources=/src/Sources"

BIN="$(swift build -c release --show-bin-path)/SemanticSpotlight"
if [ ! -x "$BIN" ]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

# A build must not create the user's engine home (~/.semsearch): recorded here, checked at the end.
ENGINE_HOME_BEFORE="$(test -e "$HOME/.semsearch" && echo yes || echo no)"

echo "==> assembling $APP"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SemanticSpotlight"
# Debug map entries (stab N_OSO) name the .o files under .build/; stripping drops them.
strip -S -x "$APP/Contents/MacOS/SemanticSpotlight"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Build stamp: the short commit (with -dirty when the tree has uncommitted changes) and the build date. Nothing absolute.
plutil -replace CFBundleVersion -string "0.1.1+$BUILD_SHA" "$APP/Contents/Info.plist"
plutil -replace SSBuildDate -string "$(date '+%-d %b %Y')" "$APP/Contents/Info.plist"
# The app icon is committed as Resources/icon/AppIcon.icns (regenerate with tools/make_icon.sh), so the build needs no network.
cp Resources/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -x "$RUNTIME_SRC/bin/semsearch" ]; then
    echo "==> bundling engine runtime from $RUNTIME_SRC"
    # ditto keeps symlinks and permissions intact.
    ditto "$RUNTIME_SRC" "$APP/Contents/Resources/runtime"
else
    # Development build: the app finds the project's .venv by itself (or from SS_ENGINE_PATH). Nothing is written to
    # the user's home.
    echo "warning: no engine runtime at $RUNTIME_SRC; the app will use the dev checkout (.venv)" >&2
fi

# Licenses ship inside the app, and beside the README in the DMG.
for f in LICENSE THIRD_PARTY_NOTICES.md; do
    if [ -f "$PROJECT_ROOT/$f" ]; then cp "$PROJECT_ROOT/$f" "$APP/Contents/Resources/$f"; else echo "warning: $f missing at $PROJECT_ROOT" >&2; fi
done

echo "==> ad-hoc codesign (whole bundle)"
codesign --force --deep -s - --entitlements Resources/SemanticSpotlight.entitlements "$APP"
codesign --verify --deep --strict "$APP"

# Fail loudly if the builder's home directory or username ended up in the bundle. Upstream wheels and the bundled
# Python carry other build machines' paths (for example /Users/runner); those are not the builder's and are accepted.
BUILDER_USER="$(id -un)"
if /usr/bin/grep -rl -a -F "$HOME" "$APP" >/dev/null; then
    echo "error: build machine home path found in $APP:" >&2
    /usr/bin/grep -rl -a -F "$HOME" "$APP" | head -5 >&2
    exit 1
fi
if /usr/bin/grep -rl -a -F "$BUILDER_USER" "$APP" >/dev/null; then
    echo "error: build machine username '$BUILDER_USER' found in $APP:" >&2
    /usr/bin/grep -rl -a -F "$BUILDER_USER" "$APP" | head -5 >&2
    exit 1
fi

# The bundled engine must be the repo's engine (a stale runtime shipped once).
./tools/check_bundled_engine.sh "$APP"

if [ "${SS_SKIP_DMG:-0}" != "1" ]; then
    ./make_dmg.sh "$APP"   # the image goes next to the app (dist/, or the staging folder)
fi

ENGINE_HOME_AFTER="$(test -e "$HOME/.semsearch" && echo yes || echo no)"
if [ "$ENGINE_HOME_BEFORE" = "no" ] && [ "$ENGINE_HOME_AFTER" = "yes" ]; then
    echo "error: this build created $HOME/.semsearch; builds must not touch the user's home" >&2
    exit 1
fi

echo "==> built $(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
