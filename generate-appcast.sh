#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/.env.local" ]; then
    set -a
    source "$SCRIPT_DIR/.env.local"
    set +a
fi

DMG_PATH="${1:-${SHOTNIX_DMG_PATH:-}}"
WEB_DIR="${SHOTNIX_WEB_DIR:-$SCRIPT_DIR/../shotnix-web}"
DOWNLOAD_DIR="$WEB_DIR/public/downloads"
APPCAST_BIN="${SHOTNIX_GENERATE_APPCAST_BIN:-$SCRIPT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast}"
SPARKLE_ACCOUNT="${SHOTNIX_SPARKLE_ACCOUNT:-ed25519}"
DOWNLOAD_URL_PREFIX="${SHOTNIX_DOWNLOAD_URL_PREFIX:-https://shotnix.com/downloads/}"
RELEASE_NOTES_URL_PREFIX="${SHOTNIX_RELEASE_NOTES_URL_PREFIX:-https://shotnix.com/downloads/}"

usage() {
    cat <<'EOF'
Usage: bash generate-appcast.sh /path/to/Shotnix-v<version>-macOS.dmg

Copies the notarized DMG into shotnix-web/public/downloads, creates a matching
Markdown release-notes file when needed, and runs Sparkle generate_appcast.

Optional environment:
  SHOTNIX_RELEASE_NOTES_FILE="/absolute/path/to/release-notes.md"
  SHOTNIX_GENERATE_APPCAST_BIN="/absolute/path/to/generate_appcast"
  SHOTNIX_SPARKLE_ACCOUNT="ed25519"
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

if [ -z "$DMG_PATH" ] || [ ! -f "$DMG_PATH" ]; then
    usage
    exit 1
fi

if [ ! -x "$APPCAST_BIN" ]; then
    echo "✗ Sparkle generate_appcast not found or not executable: $APPCAST_BIN"
    echo "  Run swift build once so SwiftPM downloads Sparkle's tools."
    exit 1
fi

mkdir -p "$DOWNLOAD_DIR"

DMG_BASENAME="$(basename "$DMG_PATH")"
ARCHIVE_DEST="$DOWNLOAD_DIR/$DMG_BASENAME"
NOTES_DEST="$DOWNLOAD_DIR/${DMG_BASENAME%.*}.md"
STAGING_DIR="$(mktemp -d "$SCRIPT_DIR/appcast-staging.XXXXXX")"
cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

echo "▶ Copying notarized DMG into website downloads…"
if [ "$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")" != "$(cd "$(dirname "$ARCHIVE_DEST")" && pwd)/$(basename "$ARCHIVE_DEST")" ]; then
    cp "$DMG_PATH" "$ARCHIVE_DEST"
fi
cp "$DMG_PATH" "$STAGING_DIR/$DMG_BASENAME"

if [ -n "${SHOTNIX_RELEASE_NOTES_FILE:-}" ]; then
    cp "$SHOTNIX_RELEASE_NOTES_FILE" "$NOTES_DEST"
elif [ ! -f "$NOTES_DEST" ]; then
    echo "▶ Creating release notes from CHANGELOG.md…"
    awk '
        /^## \[/ {
            if (seen) exit
            seen = 1
        }
        seen { print }
    ' "$SCRIPT_DIR/CHANGELOG.md" > "$NOTES_DEST"
fi
cp "$NOTES_DEST" "$STAGING_DIR/${DMG_BASENAME%.*}.md"

echo "▶ Generating Sparkle appcast…"
"$APPCAST_BIN" \
    --account "$SPARKLE_ACCOUNT" \
    --maximum-versions 0 \
    --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
    --release-notes-url-prefix "$RELEASE_NOTES_URL_PREFIX" \
    --link "https://shotnix.com/" \
    "$STAGING_DIR"

if [ ! -f "$STAGING_DIR/appcast.xml" ]; then
    echo "✗ Sparkle did not create $STAGING_DIR/appcast.xml"
    exit 1
fi

cp "$STAGING_DIR/appcast.xml" "$DOWNLOAD_DIR/appcast.xml"

echo "✓ Appcast ready: $DOWNLOAD_DIR/appcast.xml"
