#!/bin/bash
# Render the duck icon and assemble AppIcon.icns.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/Resources"
mkdir -p "$RES"

swift "$ROOT/scripts/make-icon.swift" "$RES/AppIcon-1024.png"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
while read -r px name; do
  [ -z "$px" ] && continue
  sips -z "$px" "$px" "$RES/AppIcon-1024.png" --out "$ICONSET/icon_$name.png" >/dev/null
done <<'SIZES'
16 16x16
32 16x16@2x
32 32x32
64 32x32@2x
128 128x128
256 128x128@2x
256 256x256
512 256x256@2x
512 512x512
1024 512x512@2x
SIZES

iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"
echo "wrote $RES/AppIcon.icns"
