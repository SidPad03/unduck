#!/bin/bash
# Build a shareable DMG with a drag-to-Applications layout. Writes to dist/ and
# copies into releases/. Usage: scripts/build-dmg.sh [version]  (defaults to ./VERSION)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
VERSION="${1:-$(tr -d '[:space:]' < VERSION)}"
APP_NAME="Unduck"
VOL="Unduck"
APP="dist/${APP_NAME}.app"

echo "==> Building the app"
bash scripts/package.sh "$VERSION"

echo "==> Staging DMG contents"
hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true   # clear a stale mount
STAGE="$(mktemp -d)/stage"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
swift scripts/make-dmg-bg.swift "$STAGE/.background/bg.png" >/dev/null

echo "==> Creating writable image"
RW="$(mktemp -u).dmg"
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -o "$RW" >/dev/null
DEV="$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | egrep '^/dev/' | head -1 | awk '{print $1}')"
sleep 1

if [ -n "${CI:-}" ]; then
  # No logged-in Finder to drive on a CI runner, and no way to grant it
  # Automation permission. Skip the cosmetic layout; the DMG still works.
  echo "==> CI: skipping the Finder window layout"
else
echo "==> Arranging the window (needs Finder Automation permission the first time)"
LAYOUT="$(mktemp).applescript"
cat > "$LAYOUT" <<OSA
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 120
    set background picture of opts to file ".background:bg.png"
    set position of item "${APP_NAME}.app" of container window to {150, 205}
    set position of item "Applications" of container window to {450, 205}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
perl -e 'alarm 40; exec @ARGV' osascript "$LAYOUT" >/dev/null 2>&1 \
  || echo "    layout skipped (grant Terminal control of Finder in Privacy & Security, then re-run for the arrow/background). The DMG still works."
rm -f "$LAYOUT"
fi

sync; sleep 1
hdiutil detach "$DEV" >/dev/null 2>&1 || hdiutil detach "/Volumes/$VOL" >/dev/null 2>&1 || true

echo "==> Compressing"
OUT="dist/${APP_NAME}-${VERSION}.dmg"
rm -f "$OUT"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null
rm -f "$RW"
mkdir -p releases && cp -f "$OUT" "releases/${APP_NAME}-${VERSION}.dmg"

echo ""
echo "==> DMG ready:"
echo "    $OUT"
echo "    releases/${APP_NAME}-${VERSION}.dmg   (commit this to publish)"
