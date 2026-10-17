#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_DIR="$PROJECT_DIR/dist/TravelCut.app"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$PROJECT_DIR/Resources/Info.plist")
ZIP_PATH="$PROJECT_DIR/dist/TravelCut-$VERSION-macOS.zip"
PKG_PATH="$PROJECT_DIR/dist/TravelCut-$VERSION-macOS.pkg"
CHECKSUM_PATH="$PROJECT_DIR/dist/SHA256SUMS.txt"

export COPYFILE_DISABLE=1

"$SCRIPT_DIR/build-app.sh"
rm -f "$ZIP_PATH" "$PKG_PATH" "$CHECKSUM_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
pkgbuild --component "$APP_DIR" --install-location /Applications "$PKG_PATH"
cd "$PROJECT_DIR/dist"
shasum -a 256 "${ZIP_PATH:t}" "${PKG_PATH:t}" > "$CHECKSUM_PATH"
cat "$CHECKSUM_PATH"
echo "Packaged: $ZIP_PATH"
echo "Packaged: $PKG_PATH"
