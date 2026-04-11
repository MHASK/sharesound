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

# --- stable codesign identity ----------------------------------------------
# Why we don't ad-hoc sign: ad-hoc (`--sign -`) bakes the binary's cdhash into
# the designated requirement, which changes on every rebuild. macOS TCC for
# Screen Recording keys grants on the DR, so every rebuild = "new app" =
# re-prompt + stale prior grant.
#
# Pick the most stable identity available, in order of preference:
#   1. SHAREDSOUND_SIGN_IDENTITY env var (manual override)
#   2. "Developer ID Application: …"   (Apple-issued, ideal)
#   3. "Apple Development: …"          (Apple-issued, also fine)
#   4. ad-hoc fallback (will re-prompt every build)
pick_identity() {
    if [[ -n "${SHAREDSOUND_SIGN_IDENTITY:-}" ]]; then
        echo "$SHAREDSOUND_SIGN_IDENTITY"
        return
    fi
    local listing
    listing=$(security find-identity -p codesigning -v 2>/dev/null || true)
    local pick
    pick=$(echo "$listing" | grep -o '"Developer ID Application:[^"]*"' | head -1 | tr -d '"')
    if [[ -z "$pick" ]]; then
        pick=$(echo "$listing" | grep -o '"Apple Development:[^"]*"' | head -1 | tr -d '"')
    fi
    echo "$pick"
}

SIGN_IDENTITY=$(pick_identity)

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "→ codesign with: $SIGN_IDENTITY"
    codesign --force --deep \
        --sign "$SIGN_IDENTITY" \
        --identifier dev.sharesound.SharedSound \
        --options runtime \
        "$APP_DIR" >/dev/null
else
    echo "→ no stable identity found — ad-hoc signing (TCC will re-prompt on every rebuild)"
    codesign --force --deep --sign - \
        --identifier dev.sharesound.SharedSound \
        "$APP_DIR" >/dev/null
fi

echo "→ built $APP_DIR"
echo "→ launching…"
open "$APP_DIR"
