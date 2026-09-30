#!/bin/bash
# Create (or reuse) a Gitea release for v$VERSION and upload the built .pkg.
# Matches the unified-mcp-gateway release convention (token + optional Host header).
# Env: GIT_TOKEN, VERSION and GITEA_API (all required), GITEA_HOST (optional).
# GITEA_API is the repo's API root, e.g. https://git.example.com/api/v1/repos/<owner>/unduck.
set -euo pipefail
: "${GIT_TOKEN:?need GIT_TOKEN}"; : "${VERSION:?need VERSION}"
API="${GITEA_API:?need GITEA_API (the repo API root on your Gitea)}"
host=(); [ -n "${GITEA_HOST:-}" ] && host=(-H "Host: ${GITEA_HOST}")
auth=(-H "Authorization: token ${GIT_TOKEN}")
TAG="v${VERSION}"
PKG="dist/Unduck-${VERSION}.pkg"
[ -f "$PKG" ] || { echo "missing $PKG (run scripts/package.sh $VERSION first)"; exit 1; }

curl -s -X POST "${auth[@]}" "${host[@]}" -H "Content-Type: application/json" \
     -d "{\"tag_name\":\"${TAG}\",\"target\":\"main\"}" "${API}/tags" >/dev/null || true

# A stapled ticket is what makes the package open cleanly; say which kind this is.
if xcrun stapler validate "$PKG" >/dev/null 2>&1; then
  BODY="Native arm64, Developer ID signed and notarized."
else
  BODY="Native arm64, ad-hoc signed. First launch: allow it in System Settings > Privacy & Security (or xattr -dr com.apple.quarantine the app)."
fi

RID=$(curl -s -X POST "${auth[@]}" "${host[@]}" -H "Content-Type: application/json" \
      -d "{\"tag_name\":\"${TAG}\",\"name\":\"Unduck ${TAG}\",\"body\":\"${BODY}\"}" \
      "${API}/releases" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')
[ -n "$RID" ] || { echo "could not create/resolve release for ${TAG}"; exit 1; }

curl -s -X POST "${auth[@]}" "${host[@]}" \
     -F "attachment=@${PKG}" "${API}/releases/${RID}/assets?name=Unduck-${VERSION}.pkg" >/dev/null
echo "published ${TAG} with $(basename "$PKG")"
