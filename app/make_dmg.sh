#!/usr/bin/env bash
# Packs an already-built, signed .app into dist/SemanticSpotlight.dmg with an
# /Applications link and a first-run README. Usage: ./make_dmg.sh [path/to/App.app]
set -euo pipefail

cd "$(dirname "$0")"
APP="${1:-dist/SemanticSpotlight.app}"
DMG="$(dirname "$APP")/SemanticSpotlight.dmg"   # next to the app: dist/, or a staging folder while dist/ is in use

if [ ! -d "$APP" ]; then
    echo "error: $APP not found; run build.sh first" >&2
    exit 1
fi
tools/check_bundled_engine.sh "$APP"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/ss-dmg.XXXXXX")"
STAGE="$(cd "$STAGE" && pwd -P)"   # the kernel's spelling, so the mount table matches
MNT="$STAGE.mnt"
cleanup() {   # detach the writable image even when a step fails between attach and detach
    if mount | grep -q -F " on $MNT"; then hdiutil detach -force -quiet "$MNT" || true; fi
    rm -rf "$STAGE" "$STAGE.rw.dmg" "$MNT"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "==> staging disk image contents"
ditto "$APP" "$STAGE/SemanticSpotlight.app"
ln -s /Applications "$STAGE/Applications"
cp Resources/DMG-README.txt "$STAGE/README.txt"
for f in LICENSE THIRD_PARTY_NOTICES.md; do
    if [ -f "../$f" ]; then cp "../$f" "$STAGE/$f"; else echo "warning: ../$f missing" >&2; fi
done

echo "==> creating $DMG"
rm -f "$DMG"
# Volume icon: a writable image gets the icon file and the custom-icon flag, then it is converted to compressed.
RW="$STAGE.rw.dmg"
mkdir "$MNT"
hdiutil create -quiet -volname "Semantic Spotlight" -srcfolder "$STAGE" -ov -format UDRW "$RW"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MNT" "$RW"
cp Resources/icon/AppIcon.icns "$MNT/.VolumeIcon.icns"
SetFile -a C "$MNT"
hdiutil detach -quiet "$MNT"
rm -rf "$MNT"
hdiutil convert -quiet "$RW" -format UDZO -o "$DMG"
rm -f "$RW"
hdiutil verify -quiet "$DMG"
echo "==> $DMG ($(du -h "$DMG" | cut -f1))"
