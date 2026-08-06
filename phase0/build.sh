#!/bin/bash
# Build the duckprobe Phase 0 tool. Needs only Command Line Tools (swiftc) -
# no full Xcode, no Apple Developer account.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/duckprobe"

echo "Compiling duckprobe (swiftc)…"
swiftc -O "$DIR/duckprobe.swift" -o "$BIN" \
    -framework AVFoundation -framework AudioToolbox

echo "Ad-hoc signing (gives a stable-ish identity for the mic TCC prompt)…"
codesign -s - --force "$BIN" >/dev/null 2>&1 || true

echo ""
echo "Built: $BIN"
echo "Run it with:  $BIN"
echo "('v' reproduces the duck locally and will prompt for microphone access.)"
