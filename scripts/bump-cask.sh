#!/bin/bash
# Point the Homebrew cask at a published release.
#
#   scripts/bump-cask.sh 0.1.4
#
# The cask pins an exact version and sha256, so `brew install --cask` keeps
# serving the old build until this runs. Easy to forget - publish.sh reminds you.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

VERSION="${1:-$(tr -d '[:space:]' < VERSION)}"
TAP_DIR="$(brew --repository sidpad03/tap 2>/dev/null || true)"
CASK="${TAP_DIR}/Casks/unduck.rb"
URL="https://github.com/SidPad03/unduck/releases/download/v${VERSION}/Unduck-${VERSION}.dmg"

[ -n "$TAP_DIR" ] && [ -f "$CASK" ] || {
    echo "tap not found. Add it with:  brew tap SidPad03/tap"
    exit 1
}

echo "==> Hashing the published DMG"
TMP="$(mktemp -d)/Unduck-${VERSION}.dmg"
curl -fsSL -o "$TMP" "$URL" || { echo "could not download $URL - is v${VERSION} published?"; exit 1; }
SHA="$(shasum -a 256 "$TMP" | awk '{print $1}')"
echo "    $SHA"

echo "==> Updating $CASK"
/usr/bin/sed -i '' \
    -e "s/^  version \".*\"/  version \"${VERSION}\"/" \
    -e "s/^  sha256 \".*\"/  sha256 \"${SHA}\"/" \
    "$CASK"

brew style "$CASK" >/dev/null || { echo "!! brew style failed"; exit 1; }
brew audit --cask --online sidpad03/tap/unduck || { echo "!! brew audit failed"; exit 1; }

echo "==> Committing the tap"
git -C "$TAP_DIR" add Casks/unduck.rb
if git -C "$TAP_DIR" diff --cached --quiet; then
    echo "    cask already at ${VERSION}"
else
    git -C "$TAP_DIR" commit -q -m "unduck ${VERSION}"
    git -C "$TAP_DIR" push origin main
    echo "    pushed"
fi

echo ""
echo "==> Done. Verify with:  brew update && brew info --cask sidpad03/tap/unduck"
