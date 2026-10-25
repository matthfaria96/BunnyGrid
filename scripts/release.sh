#!/bin/zsh
# Release build of BunnyGrid for distribution outside the Mac App Store.
#
# Usage: scripts/release.sh [--version X.Y.Z] [--notarize] [--arch universal|arm64] [--no-dmg]
#
# Builds (universal when every dependency builds for x86_64), bundles BunnyGrid.app with the compiled icon,
# signs it with the Hardened Runtime (Developer ID, or ad hoc when no identity is configured), verifies it,
# optionally notarizes and staples, and packs the styled DMG (scripts/make-dmg.sh).
#
# Everything account-specific comes from the environment or from scripts/release.env (gitignored; copy
# scripts/release.env.example). Variables already set in the shell win over the file.
#   BUNNYGRID_SIGN_IDENTITY       "Developer ID Application: Name (TEAMID)" or its SHA-1; unset/"-" = ad hoc
#   BUNNYGRID_NOTARY_PROFILE      keychain profile from `xcrun notarytool store-credentials` (needed by --notarize)
#   BUNNYGRID_SPARKLE_FEED_URL    https URL of appcast.xml; with the key below, enables "Check for Updates…"
#   BUNNYGRID_SPARKLE_PUBLIC_KEY  EdDSA public key printed by Sparkle's generate_keys
#   BUNNYGRID_COPYRIGHT           NSHumanReadableCopyright (default: "Copyright © <year> Matheus Faria. …")
#   BUNNYGRID_DIST_DIR            output folder (default: dist/)
#   BUNNYGRID_BUILD_DIR           SwiftPM scratch path for the release build (default: .build-release/)
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

# --- Configuration -------------------------------------------------------------------------------------------
ENV_FILE="${BUNNYGRID_RELEASE_ENV:-$ROOT/scripts/release.env}"
if [[ -f "$ENV_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ '^[[:space:]]*(#|$)' ]] && continue
    key="${line%%=*}"; value="${line#*=}"
    key="${key//[[:space:]]/}"; key="${key#export}"
    value="${value#[\"\']}"; value="${value%[\"\']}"
    [[ "$key" == BUNNYGRID_* && -z "${(P)key:-}" ]] && export "$key=$value"
  done < "$ENV_FILE"
fi

VERSION="" NOTARIZE=0 ARCH="universal" MAKE_DMG=1
while (( $# )); do
  case "$1" in
    --version) VERSION="${2:?--version needs X.Y.Z}"; shift 2 ;;
    --notarize) NOTARIZE=1; shift ;;
    --arch) ARCH="${2:?--arch needs universal|arm64}"; shift 2 ;;
    --no-dmg) MAKE_DMG=0; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "release.sh: unknown option $1" >&2; exit 64 ;;
  esac
done

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

IDENTITY="${BUNNYGRID_SIGN_IDENTITY:--}"
[[ -z "$IDENTITY" ]] && IDENTITY="-"
PROFILE="${BUNNYGRID_NOTARY_PROFILE:-}"
DIST="${BUNNYGRID_DIST_DIR:-$ROOT/dist}"
SCRATCH="${BUNNYGRID_BUILD_DIR:-$ROOT/.build-release}"
FEED="${BUNNYGRID_SPARKLE_FEED_URL:-}"
EDKEY="${BUNNYGRID_SPARKLE_PUBLIC_KEY:-}"
BUNDLE_ID="app.bunnygrid.BunnyGrid"
COPYRIGHT="${BUNNYGRID_COPYRIGHT:-Copyright © $(date +%Y) Matheus Faria. All rights reserved.}"

step() { print -P "%B==> $*%b"; }
warn() { print -P "%F{yellow}warning:%f $*" >&2; }
die() { print -P "%F{red}error:%f $*" >&2; exit 1; }

# Version: --version, else the latest vX.Y.Z tag, else 0.2.0. Build number: commit count (monotonic, which is
# what Sparkle compares).
if [[ -z "$VERSION" ]]; then
  VERSION="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//')" || true
  [[ -z "$VERSION" ]] && VERSION="0.2.0"
fi
[[ "$VERSION" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]] || die "version must look like 1.2.3 (got $VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
[[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]] && warn "working tree has uncommitted changes; build $BUILD_NUMBER ($COMMIT) will not match a commit exactly"

# Notarization needs a Developer ID identity and a stored notarytool profile; check before spending a build on it.
if (( NOTARIZE )); then
  [[ "$IDENTITY" == "-" ]] && die "--notarize needs a Developer ID identity: set BUNNYGRID_SIGN_IDENTITY (see docs/DISTRIBUTION.md)."
  [[ -z "$PROFILE" ]] && die "--notarize needs BUNNYGRID_NOTARY_PROFILE, created once with:
    xcrun notarytool store-credentials \"bunnygrid-notary\" --apple-id <apple id> --team-id <TEAMID>
  (see docs/DISTRIBUTION.md)."
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || die "notarytool profile \"$PROFILE\" was not found in the keychain (or Apple could not be reached). Create it with:
    xcrun notarytool store-credentials \"$PROFILE\" --apple-id <apple id> --team-id <TEAMID>"
fi
if [[ "$IDENTITY" != "-" ]]; then
  security find-identity -v -p codesigning | grep -qF "$IDENTITY" \
    || die "signing identity \"$IDENTITY\" is not in the keychain (security find-identity -v -p codesigning)."
fi
if [[ -n "$FEED" || -n "$EDKEY" ]]; then
  [[ -n "$FEED" && -n "$EDKEY" ]] || die "Sparkle needs both BUNNYGRID_SPARKLE_FEED_URL and BUNNYGRID_SPARKLE_PUBLIC_KEY."
  [[ "$FEED" == https://* ]] || die "BUNNYGRID_SPARKLE_FEED_URL must be https (Sparkle refuses plain http feeds)."
fi

# --- Build ---------------------------------------------------------------------------------------------------
step "Building BunnyGrid $VERSION ($BUILD_NUMBER, $COMMIT), $ARCH"
mkdir -p "$DIST"
LOG="$DIST/build.log"
ARCH_NOTE=""
build() { swift build -c release --scratch-path "$SCRATCH" "$@" >"$LOG" 2>&1; }
if [[ "$ARCH" == "universal" ]]; then
  if build --arch arm64 --arch x86_64; then
    BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" --arch arm64 --arch x86_64 --show-bin-path)"
  else
    ARCH_NOTE="universal build failed, so this is arm64 only. First errors (full log: $LOG):
$(grep -m 5 -E 'error:' "$LOG" || tail -5 "$LOG")"
    warn "$ARCH_NOTE"
    ARCH="arm64"
  fi
fi
if [[ "$ARCH" == "arm64" ]]; then
  build --arch arm64 || { tail -30 "$LOG" >&2; die "release build failed (log: $LOG)"; }
  BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH" --arch arm64 --show-bin-path)"
fi
[[ -x "$BIN_DIR/BunnyGrid" ]] || die "no BunnyGrid binary in $BIN_DIR"

# --- Bundle --------------------------------------------------------------------------------------------------
APP="$DIST/BunnyGrid.app"
step "Bundling $APP"
rm -rf "$APP" "$DIST/BunnyGrid.app.dSYM"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/BunnyGrid" "$APP/Contents/MacOS/BunnyGrid"
# Keep the symbols for crash reports, ship the binary stripped.
dsymutil "$APP/Contents/MacOS/BunnyGrid" -o "$DIST/BunnyGrid.app.dSYM" 2>/dev/null || warn "dsymutil failed; no dSYM"
strip -S -x "$APP/Contents/MacOS/BunnyGrid"
ditto "$BIN_DIR/BunnyGrid_BunnyGrid.bundle" "$APP/Contents/Resources/BunnyGrid_BunnyGrid.bundle"

SPARKLE="$(find "$BIN_DIR" "$SCRATCH/artifacts" -maxdepth 6 -type d -name Sparkle.framework -path '*macos*' -print -quit 2>/dev/null)"
[[ -z "$SPARKLE" ]] && SPARKLE="$(find "$BIN_DIR" -maxdepth 2 -type d -name Sparkle.framework -print -quit)"
[[ -n "$SPARKLE" ]] || die "Sparkle.framework not found in the build products"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
# The Installer/Downloader XPC services are only for sandboxed apps; BunnyGrid is not sandboxed.
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"

ICON_PLIST="$(mktemp -t bunnygrid-icon).plist"
xcrun actool "$ROOT/Resources/AppIcon.icon" --compile "$APP/Contents/Resources" \
  --platform macosx --target-device mac --minimum-deployment-target 14.0 \
  --app-icon AppIcon --include-all-app-icons \
  --output-partial-info-plist "$ICON_PLIST" >/dev/null
rm -f "$ICON_PLIST"

PLIST="$APP/Contents/Info.plist"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BunnyGrid</string>
  <key>CFBundleDisplayName</key><string>BunnyGrid</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>BunnyGrid</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>BunnyGridCommit</key><string>$COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>BunnyGrid connects to the database servers you add, including ones on your local network.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>BunnyGrid opens and saves the database files, SQL scripts and exports you keep in Documents.</string>
  <key>NSDesktopFolderUsageDescription</key>
  <string>BunnyGrid opens and saves the database files, SQL scripts and exports you keep on the Desktop.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>BunnyGrid opens and saves the database files, SQL scripts and exports you keep in Downloads.</string>
  <key>NSRemovableVolumesUsageDescription</key>
  <string>BunnyGrid opens database files and writes backups and exports on external drives you choose.</string>
  <key>NSNetworkVolumesUsageDescription</key>
  <string>BunnyGrid opens database files and writes backups and exports on network volumes you choose.</string>
PLIST
if [[ -n "$FEED" ]]; then
  cat >> "$PLIST" <<PLIST
  <key>SUFeedURL</key><string>$FEED</string>
  <key>SUPublicEDKey</key><string>$EDKEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
PLIST
fi
cat >> "$PLIST" <<PLIST
</dict>
</plist>
PLIST
plutil -lint -s "$PLIST"

# --- Sign ----------------------------------------------------------------------------------------------------
# Inside-out, no --deep: Sparkle's helpers, then the framework, then the app with its entitlements.
if [[ "$IDENTITY" == "-" ]]; then TIMESTAMP="--timestamp=none"; else TIMESTAMP="--timestamp"; fi
sign() {
  local out
  out="$(codesign --force --sign "$IDENTITY" --options runtime $TIMESTAMP "$@" 2>&1)" \
    || { print -r -- "$out" >&2; die "codesign failed: ${@[-1]}"; }
}
step "Signing with ${IDENTITY/#-/ad hoc identity (-)}"
FW="$APP/Contents/Frameworks/Sparkle.framework"
for helper in "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app"; do
  [[ -e "$helper" ]] && sign "$helper"
done
sign "$FW"
sign --entitlements "$ROOT/Resources/BunnyGrid.entitlements" "$APP"

step "Verifying the signature"
codesign --verify --strict --deep --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
codesign -d --verbose=2 "$APP" 2>&1 | grep -E '^(Identifier|Format|Authority|TeamIdentifier|Runtime Version|flags)|flags=' | sed 's/^/    /'
lipo -info "$APP/Contents/MacOS/BunnyGrid" | sed 's/^/    /'

# --- Notarize ------------------------------------------------------------------------------------------------
notarize() {
  local file="$1" out="$DIST/notary-$(basename "$1").json"
  step "Notarizing ${file:t} (this usually takes a few minutes)"
  xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --timeout 1h --output-format json >"$out" || true
  local nstatus="$(plutil -extract status raw -o - "$out" 2>/dev/null || echo unknown)"
  local nid="$(plutil -extract id raw -o - "$out" 2>/dev/null || echo "")"
  if [[ "$nstatus" != "Accepted" ]]; then
    [[ -n "$nid" ]] && xcrun notarytool log "$nid" --keychain-profile "$PROFILE" "$DIST/notary-log-$nid.json" >/dev/null 2>&1
    die "notarization of ${file:t} returned \"$nstatus\" (details: $out${nid:+, $DIST/notary-log-$nid.json})"
  fi
}
if (( NOTARIZE )); then
  ZIP="$DIST/BunnyGrid-notarize.zip"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP" | sed 's/^/    /'
fi

# --- DMG -----------------------------------------------------------------------------------------------------
DMG="$DIST/BunnyGrid-$VERSION.dmg"
if (( MAKE_DMG )); then
  step "Packing $DMG"
  BUNNYGRID_SIGN_IDENTITY="$IDENTITY" "$ROOT/scripts/make-dmg.sh" "$APP" "$DMG" | sed 's/^/    /'
  if (( NOTARIZE )); then
    notarize "$DMG"
    xcrun stapler staple "$DMG" | sed 's/^/    /'
  fi
fi

# --- Gatekeeper ----------------------------------------------------------------------------------------------
step "Gatekeeper assessment"
GK_APP="$(spctl -a -t exec -vv "$APP" 2>&1 || true)"
print -r -- "$GK_APP" | sed 's/^/    /'
if (( MAKE_DMG )); then
  spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/    /' || true
fi
if [[ "$IDENTITY" == "-" ]]; then
  echo "    (Expected: ad hoc builds are rejected by Gatekeeper. Downloaded copies need xattr -dr com.apple.quarantine on the app, or"
  echo "     \"Open Anyway\" in System Settings › Privacy & Security. Sign with Developer ID and --notarize to fix.)"
elif (( ! NOTARIZE )); then
  echo "    (Signed with Developer ID but not notarized: Gatekeeper blocks downloaded copies until --notarize.)"
fi

step "Done"
echo "    App:  $APP"
(( MAKE_DMG )) && echo "    DMG:  $DMG  sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "    dSYM: $DIST/BunnyGrid.app.dSYM"
echo "    Version $VERSION ($BUILD_NUMBER), $(lipo -archs "$APP/Contents/MacOS/BunnyGrid"), signed ${IDENTITY/#-/ad hoc}$( (( NOTARIZE )) && echo ', notarized and stapled')"
[[ -n "$FEED" ]] && echo "    Updates: $FEED" || echo "    Updates: off (set BUNNYGRID_SPARKLE_FEED_URL + BUNNYGRID_SPARKLE_PUBLIC_KEY)"
[[ -n "$ARCH_NOTE" ]] && warn "$ARCH_NOTE"
exit 0
