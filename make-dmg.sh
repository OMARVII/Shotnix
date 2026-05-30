#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Shotnix"
APP_PATH="$SCRIPT_DIR/$APP_NAME.app"

if [ -f "$SCRIPT_DIR/.env.local" ]; then
    set -a
    source "$SCRIPT_DIR/.env.local"
    set +a
fi

SIGN_IDENTITY="${SHOTNIX_CODESIGN_IDENTITY:-}"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH not found. Run build-app.sh first."
    exit 1
fi

VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)
PUBLIC_VERSION="${SHOTNIX_PUBLIC_VERSION:-$VERSION}"
DMG_NAME="$APP_NAME-v$PUBLIC_VERSION-macOS"
DMG_PATH="$SCRIPT_DIR/$DMG_NAME.dmg"

RW_DMG_PATH="$SCRIPT_DIR/rw.$$.$DMG_NAME.dmg"
MOUNT_DIR="$(mktemp -d "$SCRIPT_DIR/dmg-mount.XXXXXX")"
cleanup() {
    if mount | grep -q "on $MOUNT_DIR "; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || hdiutil detach -force "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    rm -rf "$MOUNT_DIR"
    rm -f "$RW_DMG_PATH"
}
trap cleanup EXIT

# Generate background image
BG_PATH="$SCRIPT_DIR/dmg-background.png"
if [ -f "$SCRIPT_DIR/make-dmg-bg.swift" ]; then
    echo "▶ Generating DMG background…"
    (cd "$SCRIPT_DIR" && swift make-dmg-bg.swift 2>/dev/null) || true
fi

echo "▶ Creating DMG installer…"

# Clean previous
rm -f "$DMG_PATH" "$RW_DMG_PATH"

echo "▶ Creating writable disk image…"
hdiutil create \
    -size 64m \
    -volname "$APP_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    "$RW_DMG_PATH"

echo "▶ Mounting disk image…"
hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$MOUNT_DIR" "$RW_DMG_PATH" >/dev/null

echo "▶ Copying app and installer assets…"
ditto --rsrc --extattr "$APP_PATH" "$MOUNT_DIR/$APP_NAME.app"
ln -s /Applications "$MOUNT_DIR/Applications"

if [ -f "$BG_PATH" ]; then
    mkdir -p "$MOUNT_DIR/.background"
    cp "$BG_PATH" "$MOUNT_DIR/.background/$(basename "$BG_PATH")"
fi

if [ -f "$SCRIPT_DIR/Branding/Shotnix.icns" ]; then
    cp "$SCRIPT_DIR/Branding/Shotnix.icns" "$MOUNT_DIR/.VolumeIcon.icns"
    if command -v SetFile >/dev/null 2>&1; then
        SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns" || true
        SetFile -a C "$MOUNT_DIR" || true
    fi
fi

echo "▶ Styling Finder window…"
/usr/bin/osascript <<EOF
on run
    set mountPath to "$MOUNT_DIR"
    set appName to "$APP_NAME"
    set backgroundName to "$(basename "$BG_PATH")"
    set backgroundAlias to POSIX file (mountPath & "/.background/" & backgroundName) as alias

    tell application "Finder"
        set dmgFolder to POSIX file mountPath as alias
        tell folder dmgFolder
            open
            tell container window
                set current view to icon view
                set toolbar visible to false
                set statusbar visible to false
                set the bounds to {200, 120, 800, 520}
            end tell

            set opts to the icon view options of container window
            tell opts
                set icon size to 128
                set text size to 16
                set arrangement to not arranged
                set background picture to backgroundAlias
            end tell

            set position of item (appName & ".app") to {120, 175}
            set extension hidden of item (appName & ".app") to true
            set position of item "Applications" to {480, 175}

            close
            open
            delay 1
            tell container window
                set statusbar visible to false
                set the bounds to {200, 120, 790, 510}
            end tell
        end tell

        delay 1

        tell folder dmgFolder
            tell container window
                set statusbar visible to false
                set the bounds to {200, 120, 800, 520}
            end tell
        end tell

        delay 2
    end tell
end run
EOF

sync
sleep 1

echo "▶ Finalizing disk image…"
rm -rf "$MOUNT_DIR/.fseventsd"
hdiutil detach "$MOUNT_DIR"

hdiutil convert "$RW_DMG_PATH" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$DMG_PATH"
rm -f "$RW_DMG_PATH"

if [ -n "$SIGN_IDENTITY" ]; then
    echo "▶ Signing DMG with $SIGN_IDENTITY…"
    SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
    if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application:* ]]; then
        SIGN_ARGS+=(--timestamp)
    fi
    codesign "${SIGN_ARGS[@]}" "$DMG_PATH"
fi

echo ""
echo "✓ Done!  $DMG_NAME.dmg created."
echo "  Upload this to your GitHub release."
echo "  For Developer ID distribution, run: bash notarize-dmg.sh \"$DMG_PATH\""
