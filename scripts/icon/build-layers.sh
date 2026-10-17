#!/bin/zsh
# Regenerates the layers of Resources/AppIcon.icon from scripts/icon/source.png (the flat 1254 px neon artwork):
#   layers.swift  splits it into bunny.png (the glowing tube, transparent elsewhere) and background.png (the gradient)
# Shadows and per-appearance (dark, tinted, clear) treatment come from icon.json and the system
# (Liquid Glass, macOS 26+; actool also emits the .icns fallback).
set -euo pipefail
HERE="${0:A:h}"; ROOT="${HERE:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK="$(mktemp -d)"
swiftc -O "$HERE/layers.swift" -o "$WORK/layers"
"$WORK/layers" "$HERE/source.png" "$WORK"
cp "$WORK"/{bunny,background}.png "$ROOT/Resources/AppIcon.icon/Assets/"
rm -rf "$WORK"
echo "Updated Resources/AppIcon.icon/Assets"
