#!/usr/bin/env bash
# Regenerates Resources/icon/AppIcon.icns from Resources/icon/AppIcon-template.svg. Needs rsvg-convert (brew install librsvg).
# Run only when the SVG changes; build.sh uses the committed .icns and needs no tools.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v rsvg-convert >/dev/null || { echo "error: rsvg-convert not found (brew install librsvg)" >&2; exit 1; }
S="$(mktemp -d "${TMPDIR:-/tmp}/ss-icon.XXXXXX")"
trap 'rm -rf "$S"' EXIT
SET="$S/AppIcon.iconset"
mkdir "$SET"
for px in 16 32 64 128 256 512 1024; do rsvg-convert -w "$px" -h "$px" Resources/icon/AppIcon-template.svg -o "$S/$px.png"; done
# iconutil's names: the 1x and 2x pairs for 16, 32, 128, 256 and 512 points.
cp "$S/16.png" "$SET/icon_16x16.png";      cp "$S/32.png" "$SET/icon_16x16@2x.png"
cp "$S/32.png" "$SET/icon_32x32.png";      cp "$S/64.png" "$SET/icon_32x32@2x.png"
cp "$S/128.png" "$SET/icon_128x128.png";   cp "$S/256.png" "$SET/icon_128x128@2x.png"
cp "$S/256.png" "$SET/icon_256x256.png";   cp "$S/512.png" "$SET/icon_256x256@2x.png"
cp "$S/512.png" "$SET/icon_512x512.png";   cp "$S/1024.png" "$SET/icon_512x512@2x.png"
iconutil -c icns "$SET" -o Resources/icon/AppIcon.icns
echo "wrote Resources/icon/AppIcon.icns"
