#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# install.sh — claude-auto-debug 설치
# 사용법: 대상 프로젝트 디렉토리에서 실행
#   cd /path/to/my-project
#   bash /path/to/claude-auto-debug/install.sh
# 또는 인자로 지정:
#   bash install.sh /path/to/my-project
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin/claude-auto-debug"
CONFIG_DIR="${HOME}/.config/claude-auto-debug"
CONFIG_FILE="${CONFIG_DIR}/config.env"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_SOURCE="${SCRIPT_DIR}/systemd/auto-debug.service"
TIMER_TEMPLATE="${SCRIPT_DIR}/systemd/auto-debug.timer.template"
SERVICE_TARGET="${SYSTEMD_USER_DIR}/auto-debug.service"
TIMER_TARGET="${SYSTEMD_USER_DIR}/auto-debug.timer"

# ── PROJECT_DIR: 인자 > 현재 디렉토리 ──────────────────────────────────────
if [[ -n "${1:-}" ]]; then
    PROJECT_DIR="$(cd "$1" && pwd)"
else
    PROJECT_DIR="$(pwd)"
fi

# claude-auto-debug 자체를 대상으로 설치하는 실수 방지
if [[ "$PROJECT_DIR" = "$SCRIPT_DIR" ]]; then
    echo "ERROR: 대상 프로젝트 디렉토리에서 실행하세요." >&2
    echo "  cd /path/to/your-project" >&2
    echo "  bash $SCRIPT_DIR/install.sh" >&2
    exit 1
fi

# git repo인지 확인
if ! git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null; then
    echo "ERROR: $PROJECT_DIR 는 git 저장소가 아닙니다." >&2
    exit 1
fi

# ── VALIDATION_CMD 자동 감지 ────────────────────────────────────────────────
detect_validation_cmd() {
    local dir="$1"

    # 프로젝트별 테스트 스크립트 우선
    if [[ -f "$dir/scripts/run-tests.sh" ]]; then
        echo "bash scripts/run-tests.sh"
    elif [[ -f "$dir/Makefile" ]] && grep -q '^test:' "$dir/Makefile" 2>/dev/null; then
        echo "make test"
    # 언어/프레임워크별 감지
    elif [[ -f "$dir/pubspec.yaml" ]]; then
        echo "dart analyze && flutter test"
    elif [[ -f "$dir/package.json" ]] && grep -q '"test"' "$dir/package.json" 2>/dev/null; then
        echo "npm test"
    elif [[ -f "$dir/pyproject.toml" ]] || [[ -f "$dir/pytest.ini" ]] || [[ -f "$dir/setup.py" ]]; then
        echo "pytest"
    elif [[ -f "$dir/Cargo.toml" ]]; then
        echo "cargo test"
    elif [[ -f "$dir/go.mod" ]]; then
        echo "go test ./..."
    else
        # 폴백: 정적 분석만
        echo "echo 'No validation command detected — skipping validation'"
    fi
}

VALIDATION_CMD="$(detect_validation_cmd "$PROJECT_DIR")"

# ── Read helper ─────────────────────────────────────────────────────────────
read_config_value() {
    local key="$1" file="$2" default="$3"
    local line
    line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 || true)"
    if [[ -z "$line" ]]; then
        printf '%s\n' "$default"
        return
    fi
    local val="${line#*=}"
    val="${val#\"}" ; val="${val%\"}"
    val="${val#\'}" ; val="${val%\'}"
    printf '%s\n' "$val"
}

# ── 설치 시작 ───────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$SYSTEMD_USER_DIR"

echo "Installing claude-auto-debug ..."
echo "  Target project: $PROJECT_DIR"
echo "  Detected validation: $VALIDATION_CMD"
echo ""

# bin/ + templates/ 복사
cp -r "${SCRIPT_DIR}/bin" "$INSTALL_DIR/"
cp -r "${SCRIPT_DIR}/templates" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bin/auto-debug.sh"

# config.env 생성 (최초) 또는 PROJECT_DIR 업데이트
if [[ ! -f "$CONFIG_FILE" ]]; then
    # 새 config 생성 — 자동 감지 값 적용
    cat > "$CONFIG_FILE" << ENVEOF
# Claude Auto-Debug — auto-generated config
# Re-run install.sh to update PROJECT_DIR and VALIDATION_CMD.

PROJECT_DIR=${PROJECT_DIR}
VALIDATION_CMD="${VALIDATION_CMD}"
ALLOWED_TOOLS=Read,Edit,Write,Glob,Grep,Bash
MAX_FILES=3
LOG_RETENTION_DAYS=30
INTERVAL=6h
ENVEOF
    echo "Created config: $CONFIG_FILE"
else
    # config 존재 — PROJECT_DIR과 VALIDATION_CMD만 업데이트
    if grep -q '^PROJECT_DIR=' "$CONFIG_FILE"; then
        sed -i "s|^PROJECT_DIR=.*|PROJECT_DIR=${PROJECT_DIR}|" "$CONFIG_FILE"
    else
        echo "PROJECT_DIR=${PROJECT_DIR}" >> "$CONFIG_FILE"
    fi
    if grep -q '^VALIDATION_CMD=' "$CONFIG_FILE"; then
        sed -i "s|^VALIDATION_CMD=.*|VALIDATION_CMD=\"${VALIDATION_CMD}\"|" "$CONFIG_FILE"
    else
        echo "VALIDATION_CMD=\"${VALIDATION_CMD}\"" >> "$CONFIG_FILE"
    fi
    echo "Updated config: PROJECT_DIR=$PROJECT_DIR"
fi

# systemd timer 생성
INTERVAL="$(read_config_value "INTERVAL" "$CONFIG_FILE" "6h")"
[[ -z "$INTERVAL" ]] && INTERVAL="6h"

rendered_timer="$(mktemp)"
trap 'rm -f "$rendered_timer"' EXIT
sed "s/%%INTERVAL%%/${INTERVAL}/g" "$TIMER_TEMPLATE" > "$rendered_timer"

install -m 0644 "$SERVICE_SOURCE" "$SERVICE_TARGET"
install -m 0644 "$rendered_timer" "$TIMER_TARGET"

systemctl --user daemon-reload
systemctl --user enable --now auto-debug.timer

echo ""
echo "=== Installation complete ==="
echo "  Project:    $PROJECT_DIR"
echo "  Validation: $VALIDATION_CMD"
echo "  Interval:   every $INTERVAL"
echo "  Config:     $CONFIG_FILE"
echo "  Logs:       journalctl --user -u auto-debug.service"
echo ""
echo "For 24/7 operation (survives logout):"
echo "  loginctl enable-linger \$(whoami)"
