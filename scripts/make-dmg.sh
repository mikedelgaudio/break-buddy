#!/bin/bash
# Builds a universal release app and packages it as build/BreakBuddy-<version>.dmg with an
# Applications shortcut for drag-to-install.
# Usage: scripts/make-dmg.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/bundle.sh" release --universal >/dev/null
APP="$ROOT/build/Break Buddy.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$ROOT/build/BreakBuddy-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Break Buddy" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
echo "$DMG"
