#!/bin/bash
# Build Unduck, assemble the .app bundle, ad-hoc sign it, and produce an
# installer .pkg. Usage: scripts/package.sh [version]  (defaults to ./VERSION)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-$(tr -d '[:space:]' < VERSION 2>/dev/null || echo 0.1.0)}"
APP_NAME="Unduck"
BUNDLE_ID="com.sigmanet.unduck"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
PKG="$DIST/$APP_NAME-$VERSION.pkg"

echo "==> Building $APP_NAME $VERSION (release)"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> Building icon"
bash "$ROOT/scripts/build-icon.sh"

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>26.1</string>
  <key>LSUIElement</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>Unduck captures your media apps' audio so it can replay it at the volume you choose while a call ducks everything else. Audio is never recorded or sent anywhere.</string>
  <key>NSMicrophoneUsageDescription</key><string>Unduck watches microphone activity to detect when a call starts and ends. It never records.</string>
  <key>UnduckUpdateBase</key><string>https://api.github.com</string>
  <key>UnduckUpdateOwner</key><string>SidPad03</string>
  <key>UnduckUpdateRepo</key><string>unduck</string>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing (no paid account needed for personal use)"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP" && echo "    signature ok"

echo "==> Building installer package"
mkdir -p "$DIST"
pkgbuild --install-location /Applications \
         --component "$APP" \
         --identifier "$BUNDLE_ID" \
         --version "$VERSION" \
         "$PKG"

echo ""
echo "==> Done."
echo "    App: $APP"
echo "    Pkg: $PKG"
