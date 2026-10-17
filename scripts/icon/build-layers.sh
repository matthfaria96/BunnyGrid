#!/bin/zsh
# Regenerates the layers of Resources/AppIcon.icon from scripts/icon/source.png (the flat 1254 px artwork):
#   layers.swift  cuts the bunny line art out into white shapes: outline.png and eye.png
# Background gradient, dark-mode colours, glass, rim, specular highlights and shadows live in icon.json and are
# drawn by the system, so the PNGs carry only shape (Liquid Glass, macOS 26+; actool also emits the .icns fallback).
set -euo pipefail
HERE="${0:A:h}"; ROOT="${HERE:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK="$(mktemp -d)"
swiftc -O "$HERE/layers.swift" -o "$WORK/layers"
"$WORK/layers" "$HERE/source.png" "$WORK"
cp "$WORK"/{outline,eye}.png "$ROOT/Resources/AppIcon.icon/Assets/"
rm -rf "$WORK"
echo "Updated Resources/AppIcon.icon/Assets"
