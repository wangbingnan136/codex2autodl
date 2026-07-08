#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="codex2autodl-control"
BIN_NAME="codex2autodl"
ICON_SOURCE="$ROOT_DIR/assets/codex2autodl-control-icon-source.png"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/build"
APP_PATH="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_PATH/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

command -v cargo >/dev/null 2>&1 || {
  echo "Error: cargo not found. Install Rust first." >&2
  exit 1
}

mkdir -p "$DIST_DIR" "$BUILD_DIR"
rm -rf "$APP_PATH"

echo "Building Rust release binary..."
cargo build --release --manifest-path "$ROOT_DIR/Cargo.toml"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/scripts" "$RESOURCES_DIR/assets"
cp "$ROOT_DIR/target/release/$BIN_NAME" "$RESOURCES_DIR/$BIN_NAME"
cp "$ROOT_DIR/scripts/setup-autodl-codex.sh" "$RESOURCES_DIR/scripts/setup-autodl-codex.sh"
chmod 0755 "$RESOURCES_DIR/$BIN_NAME" "$RESOURCES_DIR/scripts/setup-autodl-codex.sh"

cat > "$MACOS_DIR/$APP_NAME" <<'LAUNCHER'
#!/bin/sh
contents_dir="$(cd "$(dirname "$0")/.." && pwd)"
bin="$contents_dir/Resources/codex2autodl"
port="${CODEX2AUTODL_PORT:-8765}"
url="http://127.0.0.1:$port"
data_dir="${CODEX2AUTODL_HOME:-$HOME/.codex2autodl}"
log_file="$data_dir/control-panel-app.log"
pid_file="$data_dir/control-panel-app.pid"

mkdir -p "$data_dir"

if ! curl -fsS --connect-timeout 1 --max-time 2 "$url/api/profiles" >/dev/null 2>&1; then
  nohup "$bin" serve --host 127.0.0.1 --port "$port" --no-open >>"$log_file" 2>&1 &
  printf '%s\n' "$!" >"$pid_file"
fi

i=0
while [ "$i" -lt 30 ]; do
  if curl -fsS --connect-timeout 1 --max-time 2 "$url/" >/dev/null 2>&1; then
    break
  fi
  i=$((i + 1))
  sleep 0.2
done

open "$url"
exit 0
LAUNCHER
chmod 0755 "$MACOS_DIR/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>local.codex2autodl.control</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>codex2autodl</string>
  <key>CFBundleDisplayName</key>
  <string>codex2autodl</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.2.0</string>
  <key>CFBundleVersion</key>
  <string>0.2.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>12.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © codex2autodl contributors</string>
</dict>
</plist>
PLIST

if [[ -f "$ICON_SOURCE" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
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
  cp "$ICON_ICNS" "$RESOURCES_DIR/$APP_NAME.icns"
  plutil -insert CFBundleIconFile -string "$APP_NAME" "$CONTENTS_DIR/Info.plist" >/dev/null 2>&1 || \
    plutil -replace CFBundleIconFile -string "$APP_NAME" "$CONTENTS_DIR/Info.plist"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - "$APP_PATH" >/dev/null
fi

echo "Built macOS app:"
echo "  $APP_PATH"
echo
echo "Open it with:"
echo "  open $(printf '%q' "$APP_PATH")"
