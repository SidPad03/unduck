#!/bin/bash
# Build the installers on this Mac, commit them under releases/, push, and tell
# GitHub to publish the release.
#
#   scripts/publish.sh            # uses ./VERSION
#   scripts/publish.sh 0.1.4      # bumps ./VERSION first
#
# Why this triggers the workflow explicitly: push events do not currently fire
# workflow runs on this repository (see docs/ci-notes.md), so publish.yml is
# invoked through the API instead, which does work.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

VERSION="${1:-$(tr -d '[:space:]' < VERSION)}"
DMG="releases/Unduck-${VERSION}.dmg"
PKG="releases/Unduck-${VERSION}.pkg"

command -v gh >/dev/null || { echo "need the gh CLI: brew install gh"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "run: gh auth login"; exit 1; }

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || { echo "publish from main (currently on $BRANCH)"; exit 1; }

if gh release view "v${VERSION}" >/dev/null 2>&1; then
    echo "!! Release v${VERSION} already exists."
    echo "   Bump VERSION, or delete the release first:  gh release delete v${VERSION} --cleanup-tag"
    exit 1
fi

# Keep the VERSION file authoritative - the workflow and the bundle both read it.
if [ "$(tr -d '[:space:]' < VERSION)" != "$VERSION" ]; then
    echo "==> Setting VERSION to $VERSION"
    echo "$VERSION" > VERSION
fi

echo "==> Building $VERSION"
bash scripts/build-dmg.sh "$VERSION"    # produces dist/*.dmg and, via package.sh, dist/*.pkg

echo "==> Staging installers into releases/"
mkdir -p releases
cp -f "dist/Unduck-${VERSION}.dmg" "$DMG"
cp -f "dist/Unduck-${VERSION}.pkg" "$PKG"

# The version inside the bundle has to match, or the updater will keep offering
# an update the user already installed.
BUNDLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Unduck.app/Contents/Info.plist)"
[ "$BUNDLED" = "$VERSION" ] || { echo "bundle says $BUNDLED, expected $VERSION"; exit 1; }

echo "==> Committing"
git add VERSION "$DMG" "$PKG"
if git diff --cached --quiet; then
    echo "    nothing to commit (already staged/committed)"
else
    git commit -q -m "Release ${VERSION}"
fi

echo "==> Pushing"
git push origin main

echo "==> Asking GitHub to publish v${VERSION}"
gh workflow run publish.yml --ref main -f version="${VERSION}"

sleep 6
RUN_ID="$(gh run list --workflow=publish.yml --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)"
if [ -n "$RUN_ID" ]; then
    echo "    watching run $RUN_ID"
    gh run watch "$RUN_ID" --exit-status || { echo "!! publish failed - see: gh run view $RUN_ID --log-failed"; exit 1; }
fi

echo ""
echo "==> Published: $(gh release view "v${VERSION}" --json url -q .url 2>/dev/null || echo "v${VERSION}")"
echo ""
echo "    Homebrew users still get the old version until the cask is bumped:"
echo "      scripts/bump-cask.sh ${VERSION}"
