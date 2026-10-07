#!/bin/bash
# Render the duck icon and assemble AppIcon.icns.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/Resources"
mkdir -p "$RES"

# Compile instead of `swift file.swift`. The JIT interpreter looks up
# CoreGraphics overlay symbols in the running OS, which macOS 14 does not have when
# the toolchain ships a newer SDK. A compiled binary with a 14.2 target links them.
TOOL_DIR="$(mktemp -d)"
swiftc -O -target "$(uname -m)-apple-macos14.2" "$ROOT/scripts/make-icon.swift" -o "$TOOL_DIR/make-icon"
"$TOOL_DIR/make-icon" "$RES/AppIcon-1024.png"

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
