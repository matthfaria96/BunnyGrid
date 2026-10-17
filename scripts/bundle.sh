#!/bin/zsh
# Builds BunnyGrid and wraps the SwiftPM executable in a runnable .app bundle.
# Usage: scripts/bundle.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="${0:A:h:h}"
APP="$ROOT/build/BunnyGrid.app"
VERSION="0.1.0"

# Prefer the full Xcode toolchain when the active developer dir is the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/BunnyGrid"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BunnyGrid"
# SwiftPM resource bundle (SVG icons) lives in Contents/Resources so the signature stays valid.
cp -R "$(dirname "$BIN")/BunnyGrid_BunnyGrid.bundle" "$APP/Contents/Resources/"
# Sparkle (linked, inert here: no SUFeedURL in this Info.plist). The executable finds it via
# @executable_path/../Frameworks. Release builds: scripts/release.sh.
SPARKLE="$(dirname "$BIN")/Sparkle.framework"
[[ -d "$SPARKLE" ]] || SPARKLE="$(find "$ROOT/.build/artifacts" -type d -name Sparkle.framework -path '*macos*' -print -quit)"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" >/dev/null 2>&1
codesign --force --sign - "$APP/Contents/Frameworks/Sparkle.framework" >/dev/null

# App icon from Icon Composer (Resources/AppIcon.icon): actool compiles the layered Liquid Glass icon into
# Assets.car (default, dark, tinted and clear renditions on macOS 26+) plus AppIcon.icns for macOS 14–15.
ICON_PLIST="$(mktemp -t bunnygrid-icon).plist"
xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" \
  --platform macosx --target-device mac --minimum-deployment-target 14.0 \
  --app-icon AppIcon --include-all-app-icons \
  --output-partial-info-plist "$ICON_PLIST" >/dev/null

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BunnyGrid</string>
  <key>CFBundleDisplayName</key><string>BunnyGrid</string>
  <key>CFBundleIdentifier</key><string>app.bunnygrid.BunnyGrid</string>
  <key>CFBundleExecutable</key><string>BunnyGrid</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
PLIST

rm -f "$ICON_PLIST"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
