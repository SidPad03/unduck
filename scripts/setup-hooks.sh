#!/bin/bash
# Point git at the version-controlled hooks in .githooks/. Run once per clone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

chmod +x .githooks/*
git config core.hooksPath .githooks

echo "==> core.hooksPath = $(git config core.hooksPath)"
echo "    Active hooks:"
for h in .githooks/*; do echo "      $(basename "$h")"; done
echo ""
echo "    pre-push blocks pushing main unless releases/Unduck-<VERSION>.dmg is"
echo "    committed. Bypass a single push with: git push --no-verify"
