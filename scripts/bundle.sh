#!/bin/bash
# Builds BreakBuddy with SwiftPM and wraps it in a signed .app (no Xcode project needed).
# Usage: scripts/bundle.sh [debug|release] [--universal]   → build/Break Buddy.app
#   --universal builds for Apple silicon and Intel (used for the DMG).
set -euo pipefail

CONFIG="${1:-release}"
ARCHS=()
if [[ "${2:-}" == "--universal" ]]; then ARCHS=(--arch arm64 --arch x86_64); fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Break Buddy.app"
VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo 0.1)"
SHORT_VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
SHORT_VERSION="${SHORT_VERSION:-0.1.0}"

swift build --package-path "$ROOT" -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/BreakBuddy"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BreakBuddy"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.delgaudio.breakbuddy</string>
    <key>CFBundleName</key><string>Break Buddy</string>
    <key>CFBundleDisplayName</key><string>Break Buddy</string>
    <key>CFBundleExecutable</key><string>BreakBuddy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough for notifications and login items on this Mac.
codesign --force --sign - "$APP"
echo "$APP"
