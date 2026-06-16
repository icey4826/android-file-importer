#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
APP="$ROOT/outputs/Android File Importer.app"

cd "$ROOT"
./scripts/bootstrap.sh
swift build -c release --product AndroidFileImporter

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/platform-tools"
cp .build/arm64-apple-macosx/release/AndroidFileImporter "$APP/Contents/MacOS/AndroidFileImporter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Vendor/platform-tools/. "$APP/Contents/Resources/platform-tools/"
chmod +x "$APP/Contents/MacOS/AndroidFileImporter" "$APP/Contents/Resources/platform-tools/adb"
codesign --force --deep --sign - "$APP"

printf 'Built %s\n' "$APP"
