#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/.env.local" ]; then
    set -a
    source "$SCRIPT_DIR/.env.local"
    set +a
fi

DMG_PATH="${1:-${SHOTNIX_DMG_PATH:-}}"
NOTARY_PROFILE="${SHOTNIX_NOTARY_PROFILE:-}"

usage() {
    cat <<'EOF'
Usage: bash notarize-dmg.sh /path/to/Shotnix.dmg

Required local setup, not committed to git:
  1. Install your Developer ID Application certificate in Keychain.
  2. Store notary credentials in Keychain:
     xcrun notarytool store-credentials "ShotnixNotaryProfile"
  3. Copy .env.example to .env.local and set:
     SHOTNIX_NOTARY_PROFILE="ShotnixNotaryProfile"

This script submits the DMG to Apple's notary service, waits, staples the
ticket, then validates the result. It does not store Apple credentials.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    exit 0
fi

if [ -z "$DMG_PATH" ]; then
    usage
    exit 1
fi

if [ ! -f "$DMG_PATH" ]; then
    echo "✗ DMG not found: $DMG_PATH"
    exit 1
fi

if [ -z "$NOTARY_PROFILE" ]; then
    echo "✗ SHOTNIX_NOTARY_PROFILE is not set."
    echo "  Copy .env.example to .env.local and set your Keychain profile name."
    exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "✗ xcrun is required. Install Xcode command line tools first."
    exit 1
fi

echo "▶ Submitting $DMG_PATH for notarization…"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▶ Stapling notarization ticket…"
xcrun stapler staple "$DMG_PATH"

echo "▶ Validating distribution…"
if command -v syspolicy_check >/dev/null 2>&1; then
    syspolicy_check distribution "$DMG_PATH"
else
    spctl -a -t open -vvv --context context:primary-signature "$DMG_PATH"
fi

echo "✓ Notarized, stapled, and validated: $DMG_PATH"
