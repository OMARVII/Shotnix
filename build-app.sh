#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Shotnix"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
ENTITLEMENTS="$SCRIPT_DIR/Shotnix.entitlements"

if [ -f "$SCRIPT_DIR/.env.local" ]; then
    set -a
    source "$SCRIPT_DIR/.env.local"
    set +a
fi

SIGN_IDENTITY="${SHOTNIX_CODESIGN_IDENTITY:-Shotnix Local Dev}"
TIMESTAMP_MODE="${SHOTNIX_CODESIGN_TIMESTAMP:-auto}"

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

if [ -f "$SCRIPT_DIR/PrivacyInfo.xcprivacy" ]; then
    cp "$SCRIPT_DIR/PrivacyInfo.xcprivacy" "$APP_BUNDLE/Contents/Resources/PrivacyInfo.xcprivacy"
fi

echo "Signing with $SIGN_IDENTITY..."
SIGN_ARGS=(--force --deep --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENTITLEMENTS")

case "$TIMESTAMP_MODE" in
    1|true|yes|on)
        SIGN_ARGS+=(--timestamp)
        ;;
    0|false|no|off|none)
        ;;
    auto)
        if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
            SIGN_ARGS+=(--timestamp)
        fi
        ;;
    *)
        echo "✗ Invalid SHOTNIX_CODESIGN_TIMESTAMP: $TIMESTAMP_MODE"
        echo "  Use auto, true, or false."
        exit 1
        ;;
esac

codesign "${SIGN_ARGS[@]}" "$APP_BUNDLE"

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
