#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Shotnix"
APP_PATH="$SCRIPT_DIR/$APP_NAME.app"
VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
DMG_NAME="$APP_NAME-v$VERSION-macOS"
DMG_PATH="$SCRIPT_DIR/$DMG_NAME.dmg"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH not found. Run build-app.sh first."
    exit 1
fi

echo "▶ Creating DMG installer…"

# Clean previous
rm -f "$DMG_PATH"

create-dmg \
    --volname "$APP_NAME" \
    --volicon "$SCRIPT_DIR/Shotnix.icns" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 128 \
    --icon "$APP_NAME.app" 150 185 \
    --app-drop-link 450 185 \
    --hide-extension "$APP_NAME.app" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$APP_PATH"

echo ""
echo "✓ Done!  $DMG_NAME.dmg created."
echo "  Upload this to your GitHub release."
