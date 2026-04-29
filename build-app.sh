#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Shotnix"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
ENTITLEMENTS="$SCRIPT_DIR/Shotnix.entitlements"

echo "▶ Building $APP_NAME (release)…"
cd "$SCRIPT_DIR"
swift build -c release 2>&1

BINARY="$SCRIPT_DIR/.build/release/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    echo "✗ Build failed — binary not found at $BINARY"
    exit 1
fi

echo "▶ Assembling .app bundle…"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY"              "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy icon into bundle
if [ -f "$SCRIPT_DIR/Branding/Shotnix.icns" ]; then
    cp "$SCRIPT_DIR/Branding/Shotnix.icns" "$APP_BUNDLE/Contents/Resources/Shotnix.icns"
fi

echo "▶ Ad-hoc signing…"
codesign --force --deep --sign - \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$APP_BUNDLE"

echo "▶ Copying to /Applications…"
APPS_DEST="/Applications/$APP_NAME.app"
rm -rf "$APPS_DEST"
cp -R "$APP_BUNDLE" "$APPS_DEST"

echo ""
echo "✓ Done!  Shotnix.app deployed to /Applications."
echo "  Launch it from /Applications."
echo ""
echo "  First launch: grant Screen Recording permission when prompted"
echo "  (System Settings → Privacy & Security → Screen Recording)"
