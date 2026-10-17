#!/bin/zsh
# Renders every appearance of Resources/AppIcon.icon with Icon Composer's ictool.
# Usage: scripts/preview-icon.sh <output dir> [size]
set -euo pipefail
ROOT="${0:A:h:h}"; OUT="${1:?output dir}"; SIZE="${2:-512}"
IC="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
mkdir -p "$OUT"
for R in Default Dark TintedLight TintedDark ClearLight ClearDark; do
  "$IC" "$ROOT/Resources/AppIcon.icon" --export-image --output-file "$OUT/$R.png" --platform macOS \
    --rendition "$R" --width "$SIZE" --height "$SIZE" --scale 1 >/dev/null
done
echo "Previews in $OUT"
