#!/bin/zsh
# Packs a built BunnyGrid.app into a styled, compressed DMG: the app, an Applications link, a background picture
# and the Finder window layout (written as a .DS_Store by scripts/dmg/dmgtool.swift, no Finder scripting, so it
# also runs headless and on CI). Only built-in tools: hdiutil, swiftc, tiffutil, codesign.
#
# Usage: scripts/make-dmg.sh <BunnyGrid.app> <output.dmg>
# Env:   BUNNYGRID_SIGN_IDENTITY  Developer ID Application identity; the DMG is signed with it (skipped when ad hoc).
#        BUNNYGRID_VOLUME_NAME     volume name (default "BunnyGrid")
set -euo pipefail

APP="${1:?usage: make-dmg.sh <BunnyGrid.app> <output.dmg>}"
OUT="${2:?usage: make-dmg.sh <BunnyGrid.app> <output.dmg>}"
ROOT="${0:A:h:h}"
VOLNAME="${BUNNYGRID_VOLUME_NAME:-BunnyGrid}"
IDENTITY="${BUNNYGRID_SIGN_IDENTITY:--}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Window layout (points). Icons are centred on these positions.
# Everything that matters sits in the top ~300 pt: Finder adds the path/status/tab bars inside this height when
# the user has them on globally, and the bottom of the picture is what gets covered.
WIDTH=660 HEIGHT=380 ICON=128 ICON_Y=180 APP_X=170 APPS_X=490

[[ -d "$APP" ]] || { echo "make-dmg: $APP not found" >&2; exit 1; }
APP="${APP:A}"
OUT="${OUT:A}"
APP_NAME="${APP:t}"
WORK="$(mktemp -d -t bunnygrid-dmg)"
MOUNT="$WORK/mount"
cleanup() {
  [[ -d "$MOUNT" ]] && hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# 1. Tool + artwork.
xcrun swiftc -O "$ROOT/scripts/dmg/dmgtool.swift" -o "$WORK/dmgtool" 2>/dev/null
ICON_PNG="$WORK/icon.png"
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  sips -s format png -Z 256 "$APP/Contents/Resources/AppIcon.icns" --out "$ICON_PNG" >/dev/null
else
  cp "$ROOT/scripts/icon/source.png" "$ICON_PNG"
fi
"$WORK/dmgtool" background "$ICON_PNG" "$WORK" $WIDTH $HEIGHT $APP_X $APPS_X $ICON_Y
# One TIFF with both resolutions, so Retina displays get the @2x picture.
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" >/dev/null 2>&1

# 2. Staging folder → read-write HFS+ image (HFS+ so the Alias to the background resolves like Finder expects).
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
cp "$WORK/background.tiff" "$STAGE/.background/background.tiff"
if [[ -f "$APP/Contents/Resources/AppIcon.icns" ]]; then cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"; fi
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRW -size "${SIZE_MB}m" "$WORK/rw.dmg"

# 3. Mount privately (not in /Volumes, not in Finder's sidebar) and write the layout.
mkdir -p "$MOUNT"
hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen -nobrowse -mountpoint "$MOUNT" -quiet
"$WORK/dmgtool" dsstore "$MOUNT" "$VOLNAME" ".background/background.tiff" $WIDTH $HEIGHT $ICON \
  "$APP_NAME=$APP_X,$ICON_Y" "Applications=$APPS_X,$ICON_Y" ".background=$APP_X,700" ".VolumeIcon.icns=$APPS_X,700"
# Custom volume icon: kHasCustomIcon (0x0400) in the root folder's FinderInfo.
if [[ -f "$MOUNT/.VolumeIcon.icns" ]]; then
  xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MOUNT"
fi
chflags hidden "$MOUNT/.background" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet
rmdir "$MOUNT" 2>/dev/null || true

# 4. Compress (zlib, readable on every supported macOS) and sign.
mkdir -p "${OUT:h}"
rm -f "$OUT"
hdiutil convert "$WORK/rw.dmg" -quiet -format UDZO -imagekey zlib-level=9 -o "$OUT"
if [[ "$IDENTITY" != "-" ]]; then
  codesign --force --sign "$IDENTITY" --timestamp "$OUT"
fi
echo "DMG: $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
