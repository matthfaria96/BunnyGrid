#!/bin/zsh
# Regenerates the layers of Resources/AppIcon.icon from scripts/icon/source.png (the flat 1254 px artwork):
#   layers.swift      crops inside the baked rim and cuts the subject out with Vision
#   split.swift       separates the coin stack from the bunny (the paw stays on the bunny layer)
#   background.swift  draws the full-bleed background and its dark variant
# The system adds the squircle mask, rim, specular highlights and shadows, so none of them are in the PNGs.
set -euo pipefail
HERE="${0:A:h}"; ROOT="${HERE:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
WORK="$(mktemp -d)"
for s in layers split background; do swiftc -O "$HERE/$s.swift" -o "$WORK/$s"; done
"$WORK/layers" "$HERE/source.png" "$WORK"
"$WORK/split" "$WORK/subject.png" "$WORK"
"$WORK/background" "$WORK"
cp "$WORK"/{bunny,coins,background,background-dark}.png "$ROOT/Resources/AppIcon.icon/Assets/"
rm -rf "$WORK"
echo "Updated Resources/AppIcon.icon/Assets"
