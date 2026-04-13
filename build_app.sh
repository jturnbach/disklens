#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$(pwd)"
APP="$ROOT/build/DiskLens.app"
CONTENTS="$APP/Contents"

echo "› swift build (release)"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/DiskLens"
if [ ! -x "$BIN" ]; then
    echo "Binary not found at $BIN" >&2
    exit 1
fi

echo "› assembling .app bundle"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/DiskLens"
chmod +x "$CONTENTS/MacOS/DiskLens"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
printf 'APPL????' > "$CONTENTS/PkgInfo"

echo "› ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "› done: $APP"
