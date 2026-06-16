#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
PREFIX="$ROOT/Vendor"
BUILD="$ROOT/work/vendor-build"

mkdir -p "$PREFIX" "$BUILD"
if [ ! -x "$PREFIX/platform-tools/adb" ]; then
  curl -fsSL https://dl.google.com/android/repository/platform-tools-latest-darwin.zip \
    -o "$BUILD/platform-tools.zip"
  rm -rf "$PREFIX/platform-tools"
  ditto -x -k "$BUILD/platform-tools.zip" "$PREFIX"
fi

printf 'Android Platform Tools installed in %s\n' "$PREFIX/platform-tools"
