#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_DIR="$PROJECT_DIR/dist/TravelCut.app"
BUILD_FLAGS=(--disable-sandbox -c release --triple arm64-apple-macosx14.0)

cd "$PROJECT_DIR"
swift build "${BUILD_FLAGS[@]}" --product TravelCut
# The output layout differs between SwiftPM versions, so ask for it.
BIN_DIR=$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)
ARM_BINARY="$BIN_DIR/TravelCut"
RESOURCE_BUNDLE="$BIN_DIR/TravelCut_TravelCutCore.bundle"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ARM_BINARY" "$APP_DIR/Contents/MacOS/TravelCut"
cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/Resources/TravelCut_TravelCutCore.bundle"
mkdir -p "$APP_DIR/Contents/Helpers"
cp -R "$PROJECT_DIR/Resources/llama" "$APP_DIR/Contents/Helpers/llama"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/TravelCut"

plutil -lint "$APP_DIR/Contents/Info.plist"
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"
file "$APP_DIR/Contents/MacOS/TravelCut"
echo "Built: $APP_DIR"
