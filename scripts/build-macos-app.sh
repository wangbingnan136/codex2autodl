#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="codex-ssh-remote"
SOURCE_FILE="$ROOT_DIR/macos/$APP_NAME.applescript"
ICON_SOURCE="$ROOT_DIR/assets/$APP_NAME-icon-source.png"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$DIST_DIR/$APP_NAME.app"
LEGACY_APP_PATH="$DIST_DIR/AutoDL Codex Setup.app"

command -v osacompile >/dev/null 2>&1 || {
  echo "Error: osacompile not found. This builder must run on macOS." >&2
  exit 1
}

[[ -f "$SOURCE_FILE" ]] || {
  echo "Error: missing AppleScript source: $SOURCE_FILE" >&2
  exit 1
}

[[ -f "$ICON_SOURCE" ]] || {
  echo "Error: missing icon source: $ICON_SOURCE" >&2
  exit 1
}

command -v sips >/dev/null 2>&1 || {
  echo "Error: sips not found. This builder must run on macOS." >&2
  exit 1
}

command -v iconutil >/dev/null 2>&1 || {
  echo "Error: iconutil not found. This builder must run on macOS." >&2
  exit 1
}

mkdir -p "$DIST_DIR" "$BUILD_DIR"
rm -rf "$APP_PATH" "$LEGACY_APP_PATH"

osacompile -o "$APP_PATH" "$SOURCE_FILE"

ICON_WORK_DIR="$BUILD_DIR/icon"
ICONSET_DIR="$ICON_WORK_DIR/$APP_NAME.iconset"
ICON_MASTER="$ICON_WORK_DIR/$APP_NAME-1024.png"
ICON_ICNS="$ICON_WORK_DIR/$APP_NAME.icns"

rm -rf "$ICONSET_DIR" "$ICON_MASTER" "$ICON_ICNS"
mkdir -p "$ICON_WORK_DIR" "$ICONSET_DIR"

sips -s format png -Z 900 "$ICON_SOURCE" --out "$ICON_WORK_DIR/$APP_NAME-resized.png" >/dev/null 2>&1
sips --padToHeightWidth 1024 1024 --padColor FFFFFF "$ICON_WORK_DIR/$APP_NAME-resized.png" --out "$ICON_MASTER" >/dev/null 2>&1

make_icon_png() {
  local size="$1"
  local output="$2"
  sips -z "$size" "$size" "$ICON_MASTER" --out "$output" >/dev/null 2>&1
}

make_icon_png 16 "$ICONSET_DIR/icon_16x16.png"
make_icon_png 32 "$ICONSET_DIR/icon_16x16@2x.png"
make_icon_png 32 "$ICONSET_DIR/icon_32x32.png"
make_icon_png 64 "$ICONSET_DIR/icon_32x32@2x.png"
make_icon_png 128 "$ICONSET_DIR/icon_128x128.png"
make_icon_png 256 "$ICONSET_DIR/icon_128x128@2x.png"
make_icon_png 256 "$ICONSET_DIR/icon_256x256.png"
make_icon_png 512 "$ICONSET_DIR/icon_256x256@2x.png"
make_icon_png 512 "$ICONSET_DIR/icon_512x512.png"
make_icon_png 1024 "$ICONSET_DIR/icon_512x512@2x.png"

iconutil -c icns -o "$ICON_ICNS" "$ICONSET_DIR"
cp "$ICON_ICNS" "$APP_PATH/Contents/Resources/$APP_NAME.icns"

INFO_PLIST="$APP_PATH/Contents/Info.plist"
for key in \
  NSAppleMusicUsageDescription \
  NSCalendarsUsageDescription \
  NSCameraUsageDescription \
  NSContactsUsageDescription \
  NSHomeKitUsageDescription \
  NSMicrophoneUsageDescription \
  NSPhotoLibraryUsageDescription \
  NSRemindersUsageDescription \
  NSSiriUsageDescription \
  NSSystemAdministrationUsageDescription
do
  plutil -remove "$key" "$INFO_PLIST" >/dev/null 2>&1 || true
done

plutil -replace CFBundleIconFile -string "$APP_NAME" "$INFO_PLIST"
plutil -replace CFBundleIconName -string "$APP_NAME" "$INFO_PLIST"
plutil -replace NSAppleEventsUsageDescription \
  -string "codex-ssh-remote opens Terminal to run the local setup script and show progress logs." \
  "$INFO_PLIST"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP_PATH" >/dev/null
fi

echo "Built macOS app:"
echo "  $APP_PATH"
echo
echo "Open it with:"
echo "  open $(printf '%q' "$APP_PATH")"
