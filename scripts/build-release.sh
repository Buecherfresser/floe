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

echo "==> Creating app icon..."
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 128 256 512; do
    sips -z $size $size Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
# 32 and 64 px are tidied by hand so the face stays crisp. iconutil stores
# 16 and 32 px @1x in a legacy format that garbles the transparent edge,
# so macOS scales those down from the @2x images instead.
cp Assets/AppIcon-32.png "$ICONSET/icon_16x16@2x.png"
cp Assets/AppIcon-64.png "$ICONSET/icon_32x32@2x.png"
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

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

# A stable identity keeps the Accessibility grant valid across rebuilds;
# ad-hoc signatures change with every build and invalidate it.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)}"

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "==> Code signing ($SIGN_IDENTITY)..."
    codesign --force --sign "$SIGN_IDENTITY" --deep "$APP_BUNDLE"
else
    echo "==> Code signing (ad-hoc — Accessibility must be re-granted after each build)..."
    codesign --force --sign - --deep "$APP_BUNDLE"
fi

echo ""
echo "Done! Built ${APP_NAME}.app ${VERSION}"
echo "  ${APP_BUNDLE}"
echo ""
echo "To install:  cp -R dist/${APP_NAME}.app /Applications/"
echo "To run:      open dist/${APP_NAME}.app"
