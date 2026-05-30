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
SPARKLE_PUBLIC_ED_KEY="${SHOTNIX_SPARKLE_PUBLIC_ED_KEY:-}"
REQUIRE_SPARKLE_KEY="${SHOTNIX_REQUIRE_SPARKLE_KEY:-false}"

echo "▶ Building $APP_NAME (release)…"
cd "$SCRIPT_DIR"
swift build -c release 2>&1
BUILD_DIR="$(swift build -c release --show-bin-path)"

BINARY="$BUILD_DIR/$APP_NAME"
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

if [ -n "$SPARKLE_PUBLIC_ED_KEY" ]; then
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$APP_BUNDLE/Contents/Info.plist"
elif [[ "$REQUIRE_SPARKLE_KEY" =~ ^(1|true|yes|on)$ ]]; then
    echo "✗ SHOTNIX_SPARKLE_PUBLIC_ED_KEY is required when SHOTNIX_REQUIRE_SPARKLE_KEY=true."
    echo "  Generate it with Sparkle's generate_keys tool and keep the private key out of git."
    exit 1
else
    echo "⚠ Sparkle public key not set; update checks will be disabled in this build."
fi

# Copy icon into bundle
if [ -f "$SCRIPT_DIR/Branding/Shotnix.icns" ]; then
    cp "$SCRIPT_DIR/Branding/Shotnix.icns" "$APP_BUNDLE/Contents/Resources/Shotnix.icns"
fi

if [ -f "$SCRIPT_DIR/PrivacyInfo.xcprivacy" ]; then
    cp "$SCRIPT_DIR/PrivacyInfo.xcprivacy" "$APP_BUNDLE/Contents/Resources/PrivacyInfo.xcprivacy"
fi

if [ -f "$SCRIPT_DIR/THIRD_PARTY_NOTICES.md" ]; then
    cp "$SCRIPT_DIR/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"
fi

# Copy SPM-generated resource bundles (capture sound, KeyboardShortcuts localizations, etc.)
while IFS= read -r bundle; do
    bundle_name="$(basename "$bundle")"
    if [ "$bundle_name" = "${APP_NAME}_${APP_NAME}.bundle" ]; then
        continue
    fi
    ditto "$bundle" "$APP_BUNDLE/Contents/Resources/$bundle_name"
done < <(find "$BUILD_DIR" -maxdepth 1 -type d -name "*.bundle" -print)

SPARKLE_FRAMEWORK="$BUILD_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "✗ Sparkle.framework not found at $SPARKLE_FRAMEWORK"
    exit 1
fi

echo "▶ Embedding Sparkle.framework…"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

if ! otool -L "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -q "@rpath/Sparkle.framework"; then
    echo "✗ Built binary is not linked against Sparkle.framework"
    exit 1
fi

if ! otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -q "@executable_path/../Frameworks"; then
    echo "✗ Built binary is missing @executable_path/../Frameworks rpath"
    exit 1
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
