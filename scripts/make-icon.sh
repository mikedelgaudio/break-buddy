#!/bin/bash
# Builds Resources/AppIcon.icns from design/icon/artwork.png.
# Usage: scripts/make-icon.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift "$ROOT/scripts/make-icon.swift" "$ROOT/design/icon/artwork.png" "$ROOT/design/icon/AppIcon-1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$ROOT/design/icon/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "$ROOT/design/icon/AppIcon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
mkdir -p "$ROOT/Resources"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "$ROOT/Resources/AppIcon.icns"
