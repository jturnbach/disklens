#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="$ROOT/build/DiskLens.app"
STAGE="$ROOT/build/dmg_staging"
DMG="$ROOT/build/DiskLens-1.0.0.dmg"
VOLNAME="DiskLens"

if [ ! -d "$APP" ]; then
    echo "App not found at $APP — run build_app.sh first." >&2
    exit 1
fi

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/DiskLens.app"
ln -s /Applications "$STAGE/Applications"

# Custom volume icon: reuse the app icon.
cp "$ROOT/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"

echo "› hdiutil create"
hdiutil create \
    -volname "$VOLNAME" \
    -srcfolder "$STAGE" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    -imagekey zlib-level=9 \
    "$DMG"

echo "› done: $DMG"
ls -lh "$DMG"
