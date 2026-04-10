#!/usr/bin/env bash
# Builds SharedSound and wraps the binary in a proper macOS .app bundle so
# Local Network permission + Bonjour discovery work. On macOS 15+ NWBrowser
# silently returns nothing unless Info.plist declares NSBonjourServices, and
# TCC won't prompt for Local Network access without NSLocalNetworkUsageDescription.
set -euo pipefail

CONFIG="${1:-debug}"
cd "$(dirname "$0")/.."

echo "→ swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN_PATH=$(swift build -c "$CONFIG" --show-bin-path)
APP_DIR="build/SharedSound.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$BIN_PATH/SharedSoundApp" "$MACOS_DIR/SharedSoundApp"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SharedSoundApp</string>
    <key>CFBundleIdentifier</key>
    <string>dev.sharesound.SharedSound</string>
    <key>CFBundleName</key>
    <string>SharedSound</string>
    <key>CFBundleDisplayName</key>
    <string>SharedSound</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>SharedSound discovers other SharedSound devices on your Wi-Fi network and streams audio between them.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_sharedsound._tcp</string>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc codesign so TCC can key permissions to this bundle.
codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "→ built $APP_DIR"
echo "→ launching…"
open "$APP_DIR"
