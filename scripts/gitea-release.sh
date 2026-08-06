#!/bin/bash
# Create (or reuse) a Gitea release for v$VERSION and upload the built .pkg.
# Matches the unified-mcp-gateway release convention (token + optional Host header).
# Env: GIT_TOKEN (required), VERSION (required), GITEA_API, GITEA_HOST (optional).
set -euo pipefail
: "${GIT_TOKEN:?need GIT_TOKEN}"; : "${VERSION:?need VERSION}"
API="${GITEA_API:-https://git.sigmanet.com/api/v1/repos/sid/unduck}"
host=(); [ -n "${GITEA_HOST:-}" ] && host=(-H "Host: ${GITEA_HOST}")
auth=(-H "Authorization: token ${GIT_TOKEN}")
TAG="v${VERSION}"
PKG="dist/Unduck-${VERSION}.pkg"
[ -f "$PKG" ] || { echo "missing $PKG (run scripts/package.sh $VERSION first)"; exit 1; }

curl -s -X POST "${auth[@]}" "${host[@]}" -H "Content-Type: application/json" \
     -d "{\"tag_name\":\"${TAG}\",\"target\":\"main\"}" "${API}/tags" >/dev/null || true

RID=$(curl -s -X POST "${auth[@]}" "${host[@]}" -H "Content-Type: application/json" \
      -d "{\"tag_name\":\"${TAG}\",\"name\":\"Unduck ${TAG}\",\"body\":\"Native arm64, ad-hoc signed. First launch: allow it in System Settings > Privacy & Security (or xattr -dr com.apple.quarantine the app).\"}" \
      "${API}/releases" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')
[ -n "$RID" ] || { echo "could not create/resolve release for ${TAG}"; exit 1; }

curl -s -X POST "${auth[@]}" "${host[@]}" \
     -F "attachment=@${PKG}" "${API}/releases/${RID}/assets?name=Unduck-${VERSION}.pkg" >/dev/null
echo "published ${TAG} with $(basename "$PKG")"
