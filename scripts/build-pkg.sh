#!/bin/bash
# Build a shareable Unduck installer and drop it in ~/Downloads.
# The .pkg contains only the compiled app (no source). Usage: scripts/build-pkg.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(tr -d '[:space:]' < VERSION 2>/dev/null || echo 0.1.0)"
bash scripts/package.sh "$VERSION"

mkdir -p releases
DEST="releases/Unduck-$VERSION.pkg"
cp -f "dist/Unduck-$VERSION.pkg" "$DEST"

echo ""
echo "Installer saved into the repo at: $DEST"
echo "Publish it by committing:"
echo "  git add $DEST && git commit -m \"Release $VERSION\" && git push"
