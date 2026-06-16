#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
BUILD="$ROOT/work/vendor-build"
PREFIX="$ROOT/Vendor"
LIBUSB_VERSION=1.0.30
LIBMTP_VERSION=1.1.23

mkdir -p "$BUILD" "$PREFIX"

fetch_unpack() {
  url=$1
  archive=$2
  directory=$3
  if [ ! -d "$BUILD/$directory" ]; then
    curl -fsSL "$url" -o "$BUILD/$archive"
    case "$archive" in
      *.tar.bz2) tar -xjf "$BUILD/$archive" -C "$BUILD" ;;
      *.tar.gz) tar -xzf "$BUILD/$archive" -C "$BUILD" ;;
    esac
  fi
}

fetch_unpack \
  "https://github.com/libusb/libusb/releases/download/v$LIBUSB_VERSION/libusb-$LIBUSB_VERSION.tar.bz2" \
  "libusb-$LIBUSB_VERSION.tar.bz2" "libusb-$LIBUSB_VERSION"

if [ ! -f "$PREFIX/lib/libusb-1.0.dylib" ]; then
  cd "$BUILD/libusb-$LIBUSB_VERSION"
  ./configure --prefix="$PREFIX" --disable-static
  make -j"$(sysctl -n hw.logicalcpu)"
  make install
fi

fetch_unpack \
  "https://github.com/libmtp/libmtp/releases/download/v$LIBMTP_VERSION/libmtp-$LIBMTP_VERSION.tar.gz" \
  "libmtp-$LIBMTP_VERSION.tar.gz" "libmtp-$LIBMTP_VERSION"

if [ ! -f "$PREFIX/lib/libmtp.dylib" ]; then
  cat > "$BUILD/pkg-config" <<EOF
#!/bin/sh
case "\$*" in
  *--exists*) exit 0 ;;
  *--modversion*) echo "$LIBUSB_VERSION" ;;
  *--cflags*) echo "-I$PREFIX/include/libusb-1.0" ;;
  *--libs*) echo "-L$PREFIX/lib -lusb-1.0" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$BUILD/pkg-config"
  cd "$BUILD/libmtp-$LIBMTP_VERSION"
  PKG_CONFIG="$BUILD/pkg-config" PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
    ./configure --prefix="$PREFIX" --disable-static --with-udev=no
  make -j"$(sysctl -n hw.logicalcpu)"
  make install
fi

printf 'MTP dependencies installed in %s\n' "$PREFIX"

if [ ! -x "$PREFIX/platform-tools/adb" ]; then
  curl -fsSL https://dl.google.com/android/repository/platform-tools-latest-darwin.zip \
    -o "$BUILD/platform-tools.zip"
  rm -rf "$PREFIX/platform-tools"
  ditto -x -k "$BUILD/platform-tools.zip" "$PREFIX"
fi

printf 'Android Platform Tools installed in %s\n' "$PREFIX/platform-tools"
