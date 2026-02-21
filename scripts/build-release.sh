#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Floe"
BUNDLE_ID="com.jonasdrechsel.floe"
VERSION="${1:-0.1.0}"
BUILD_DIR="$(pwd)/.build/release"
APP_BUNDLE="$(pwd)/dist/${APP_NAME}.app"

echo "==> Building ${APP_NAME} ${VERSION} (release)..."
swift build -c release

echo "==> Assembling ${APP_NAME}.app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 Jonas Drechsel. All rights reserved.</string>
</dict>
</plist>
PLIST

echo "==> Code signing (ad-hoc)..."
codesign --force --sign - --deep "$APP_BUNDLE"

echo ""
echo "Done! Built ${APP_NAME}.app ${VERSION}"
echo "  ${APP_BUNDLE}"
echo ""
echo "To install:  cp -R dist/${APP_NAME}.app /Applications/"
echo "To run:      open dist/${APP_NAME}.app"
