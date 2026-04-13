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

# SwiftPM puts processed resources in a .bundle next to the binary.
# Bundle.module probes several locations; Contents/Resources works and is
# the correct place for non-binary resources in an .app bundle.
BIN_DIR="$(dirname "$BIN")"
for bundle in "$BIN_DIR"/*.bundle; do
    if [ -e "$bundle" ]; then
        cp -R "$bundle" "$CONTENTS/Resources/"
    fi
done

echo "› ad-hoc codesign"
codesign --force --deep --sign - "$APP"

echo "› done: $APP"
