#!/bin/zsh
# Regenerates Resources/AppIcon.icon from scripts/icon/source.png (the flat full-bleed artwork, red background
# with the white bunny). The artwork is used as a single layer so it renders exactly as drawn; the system applies
# the squircle mask and the per-appearance treatment (actool also emits the .icns fallback).
set -euo pipefail
HERE="${0:A:h}"; ROOT="${HERE:h:h}"
sips -s format png -z 1024 1024 "$HERE/source.png" --out "$ROOT/Resources/AppIcon.icon/Assets/artwork.png" >/dev/null
echo "Updated Resources/AppIcon.icon/Assets/artwork.png"
