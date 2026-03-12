#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# setup.sh — claude-auto-debug 원라인 설치 부트스트랩
# 사용법: 대상 프로젝트 디렉토리에서 실행
#   cd /path/to/my-project
#   bash <(curl -fsSL https://raw.githubusercontent.com/inhyoe/claude-auto-debug/main/setup.sh)
# ---------------------------------------------------------------------------

REPO="https://github.com/inhyoe/claude-auto-debug.git"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading claude-auto-debug ..."
git clone --depth 1 "$REPO" "$TMPDIR/claude-auto-debug"

echo ""
bash "$TMPDIR/claude-auto-debug/install.sh" "$@"
