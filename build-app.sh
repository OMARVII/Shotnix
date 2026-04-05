#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Shotnix"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
DEST="$HOME/Desktop/$APP_NAME.app"

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

# Regenerate icon if script exists
if [ -f "$SCRIPT_DIR/make-icon.swift" ]; then
    echo "▶ Regenerating icon…"
    (cd "$SCRIPT_DIR" && swift make-icon.swift 2>/dev/null) || true
fi

# Copy icon into bundle
if [ -f "$SCRIPT_DIR/Shotnix.icns" ]; then
    cp "$SCRIPT_DIR/Shotnix.icns" "$APP_BUNDLE/Contents/Resources/Shotnix.icns"
fi

# Write entitlements for ScreenCaptureKit
cat > /tmp/Shotnix.entitlements <<'ENTITLEMENTS'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.cs.allow-jit</key>
    <false/>
</dict>
</plist>
ENTITLEMENTS

echo "▶ Ad-hoc signing…"
codesign --force --deep --sign - \
    --entitlements /tmp/Shotnix.entitlements \
    "$APP_BUNDLE"

echo "▶ Copying to Desktop…"
rm -rf "$DEST"
cp -R "$APP_BUNDLE" "$DEST"

# Remove quarantine so it opens without Gatekeeper prompt
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo ""
echo "✓ Done!  Shotnix.app is on your Desktop."
echo "  Double-click it to launch."
echo ""
echo "  First launch: grant Screen Recording permission when prompted"
echo "  (System Settings → Privacy & Security → Screen Recording)"
