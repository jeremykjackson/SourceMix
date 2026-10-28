#!/usr/bin/env bash
# Builds SourceMix.app (universal, ad-hoc signed) into ./build.
#   ./scripts/build-app.sh            # release build
#   ./scripts/build-app.sh --install  # also copy to /Applications and launch
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="SourceMix"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

ARCHS=(--arch arm64)
if [[ "${UNIVERSAL:-1}" == "1" ]]; then ARCHS=(--arch arm64 --arch x86_64); fi

echo "▸ Compiling ($(swift --version 2>/dev/null | head -1))"
swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

echo "▸ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Sources/SourceMix/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Signing (ad-hoc)"
codesign --force --deep --sign - --timestamp=none "$APP"

echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  open "/Applications/$APP_NAME.app"
  echo "✓ Installed to /Applications and launched — look for the EQ icon in your menu bar."
fi
