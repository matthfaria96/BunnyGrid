#!/bin/zsh
# Sparkle appcast for BunnyGrid updates, with Sparkle's own generate_appcast (shipped in the Sparkle SwiftPM
# artifact, so no separate download).
#
# Usage:
#   scripts/appcast.sh --generate-keys        once: creates the EdDSA key pair (private key stays in your login
#                                             keychain) and prints the public key for BUNNYGRID_SPARKLE_PUBLIC_KEY
#   scripts/appcast.sh [updates dir]          (re)generates <updates dir>/appcast.xml from every
#                                             BunnyGrid-X.Y.Z.dmg in it (default: dist/updates)
#
# Keep every published DMG in the updates folder: generate_appcast reads them to build the item list (and
# delta updates). Release notes: put BunnyGrid-X.Y.Z.html (or .md) next to the DMG.
#
# Env (or scripts/release.env):
#   BUNNYGRID_SPARKLE_FEED_URL          the appcast URL; DMG links default to the same folder
#   BUNNYGRID_SPARKLE_DOWNLOAD_PREFIX   where the DMGs are served, if not next to the appcast
#   BUNNYGRID_SPARKLE_PRIVATE_KEY_FILE  EdDSA private key file instead of the keychain (CI)
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
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
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# Sparkle's command-line tools come with the binary artifact SwiftPM downloads.
TOOLS=""
for dir in "${BUNNYGRID_BUILD_DIR:-$ROOT/.build-release}" "$ROOT/.build"; do
  [[ -x "$dir/artifacts/sparkle/Sparkle/bin/generate_appcast" ]] && { TOOLS="$dir/artifacts/sparkle/Sparkle/bin"; break; }
done
if [[ -z "$TOOLS" ]]; then
  swift package resolve >/dev/null
  swift build --product BunnyGrid >/dev/null 2>&1 || true   # downloads the binary artifact
  [[ -x "$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast" ]] && TOOLS="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
fi
[[ -n "$TOOLS" ]] || { echo "appcast.sh: Sparkle tools not found; run scripts/release.sh first" >&2; exit 1; }

if [[ "${1:-}" == "--generate-keys" ]]; then
  "$TOOLS/generate_keys"
  echo
  echo "Put the public key above in BUNNYGRID_SPARKLE_PUBLIC_KEY (scripts/release.env)."
  echo "Back up the private key: $TOOLS/generate_keys -x sparkle-private-key.txt (store it safely, never commit it)."
  exit 0
fi

UPDATES="${1:-$ROOT/dist/updates}"
[[ -d "$UPDATES" ]] || { echo "appcast.sh: $UPDATES does not exist; copy the release DMG(s) into it" >&2; exit 1; }
ls "$UPDATES"/*.dmg >/dev/null 2>&1 || { echo "appcast.sh: no .dmg in $UPDATES" >&2; exit 1; }
FEED="${BUNNYGRID_SPARKLE_FEED_URL:-}"
[[ -n "$FEED" ]] || { echo "appcast.sh: set BUNNYGRID_SPARKLE_FEED_URL (the URL appcast.xml will be served from)" >&2; exit 1; }
PREFIX="${BUNNYGRID_SPARKLE_DOWNLOAD_PREFIX:-${FEED%/*}/}"

ARGS=(--download-url-prefix "$PREFIX" -o "$UPDATES/appcast.xml")
[[ -n "${BUNNYGRID_SPARKLE_PRIVATE_KEY_FILE:-}" ]] && ARGS+=(--ed-key-file "$BUNNYGRID_SPARKLE_PRIVATE_KEY_FILE")
"$TOOLS/generate_appcast" "${ARGS[@]}" "$UPDATES"
echo "Appcast: $UPDATES/appcast.xml"
echo "Upload appcast.xml to $FEED and the DMG(s) to $PREFIX"
