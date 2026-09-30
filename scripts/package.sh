#!/bin/bash
# Build Unduck, assemble the .app bundle, sign it, and produce an installer .pkg.
# Usage: scripts/package.sh [version]  (defaults to ./VERSION)
#
# Signs with the Developer ID identities in the keychain when there are any, and
# ad-hoc otherwise (resolve_signing in scripts/lib.sh). NOTARIZE=1 also
# notarizes and staples the .pkg (build-dmg.sh does the .dmg); it needs both
# Developer ID identities and credentials - see notary_ready in scripts/lib.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
source "$ROOT/scripts/lib.sh"

VERSION="${1:-$(tr -d '[:space:]' < VERSION 2>/dev/null || echo 0.1.0)}"
APP_NAME="Unduck"
BUNDLE_ID="com.sigmanet.unduck"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
PKG="$DIST/$APP_NAME-$VERSION.pkg"

# Resolved before building, so a release that can't be notarized fails in
# seconds rather than after the compile.
resolve_signing
if [ "${NOTARIZE:-0}" = 1 ]; then
    [ "$SIGN_ID" != "-" ] || { echo "!! NOTARIZE=1 needs a Developer ID Application identity" >&2; exit 1; }
    [ -n "$PKG_NAME" ]    || { echo "!! NOTARIZE=1 needs a Developer ID Installer identity" >&2; exit 1; }
    notary_ready          || { echo "!! NOTARIZE=1 needs NOTARY_PROFILE, or APPLE_ID + APPLE_PASSWORD + APPLE_TEAM_ID" >&2; exit 1; }
fi

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

# Hardened runtime and a secure timestamp are what notarization requires. The
# entitlements are the same either way, so an ad-hoc build behaves like a
# release under the hardened runtime instead of hiding a missing one.
echo "==> Signing with: $SIGN_NAME"
if [ "$SIGN_ID" = "-" ]; then
    codesign --force --options runtime --entitlements "$ROOT/Resources/Unduck.entitlements" \
        --sign - "$APP"
else
    codesign --force --options runtime --timestamp --entitlements "$ROOT/Resources/Unduck.entitlements" \
        --sign "$SIGN_ID" "$APP"
fi
codesign --verify --deep --strict "$APP" && echo "    signature ok"

echo "==> Building installer package"
mkdir -p "$DIST"
if [ -n "$PKG_NAME" ]; then
    echo "    signing with: $PKG_NAME"
    pkgbuild --install-location /Applications --component "$APP" \
             --identifier "$BUNDLE_ID" --version "$VERSION" \
             --sign "$PKG_NAME" --timestamp "$PKG"
else
    pkgbuild --install-location /Applications --component "$APP" \
             --identifier "$BUNDLE_ID" --version "$VERSION" "$PKG"
fi

if [ "${NOTARIZE:-0}" = 1 ]; then
    notarize "$PKG"
fi

echo ""
echo "==> Done."
echo "    App: $APP"
echo "    Pkg: $PKG"
