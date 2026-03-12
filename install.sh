#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# install.sh — claude-auto-debug 설치
# 사용법:
#   cd /path/to/my-project && bash install.sh
#   bash install.sh --interval 12h --max-files 5
#   bash <(curl ...) --interval 1d --allowed-tools "Read,Grep"
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

# ── 옵션 파싱 ──────────────────────────────────────────────────────────────
OPT_PROJECT=""
OPT_INTERVAL=""
OPT_MAX_FILES=""
OPT_ALLOWED_TOOLS=""
OPT_VALIDATION=""
OPT_LOG_RETENTION=""

show_help() {
    cat <<'HELPEOF'
Usage: install.sh [OPTIONS] [PROJECT_DIR]

Options:
  --interval TIME        실행 주기 (기본: 6h). 예: 30m, 1h, 6h, 1d
  --max-files N          1회 최대 수정 파일 수 (기본: 3)
  --allowed-tools LIST   Claude 허용 도구 (기본: Read,Edit,Write,Glob,Grep,Bash)
  --validation CMD       검증 명령어 (기본: 자동 감지)
  --log-retention DAYS   로그 보존 기간 (기본: 30)
  -h, --help             도움말

Examples:
  cd ~/my-project && bash install.sh
  bash install.sh --interval 12h --max-files 5
  bash install.sh --interval 1d ~/my-project
HELPEOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval)      OPT_INTERVAL="$2"; shift 2 ;;
        --max-files)     OPT_MAX_FILES="$2"; shift 2 ;;
        --allowed-tools) OPT_ALLOWED_TOOLS="$2"; shift 2 ;;
        --validation)    OPT_VALIDATION="$2"; shift 2 ;;
        --log-retention) OPT_LOG_RETENTION="$2"; shift 2 ;;
        -h|--help)       show_help ;;
        -*)              echo "Unknown option: $1" >&2; show_help ;;
        *)               OPT_PROJECT="$1"; shift ;;
    esac
done

# ── PROJECT_DIR: 인자 > 현재 디렉토리 ──────────────────────────────────────
if [[ -n "$OPT_PROJECT" ]]; then
    PROJECT_DIR="$(cd "$OPT_PROJECT" && pwd)"
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

# CLI 옵션 우선, 없으면 자동 감지
if [[ -n "$OPT_VALIDATION" ]]; then
    VALIDATION_CMD="$OPT_VALIDATION"
else
    VALIDATION_CMD="$(detect_validation_cmd "$PROJECT_DIR")"
fi

# 나머지 옵션 기본값
INTERVAL="${OPT_INTERVAL:-6h}"
MAX_FILES="${OPT_MAX_FILES:-3}"
ALLOWED_TOOLS="${OPT_ALLOWED_TOOLS:-Read,Edit,Write,Glob,Grep,Bash}"
LOG_RETENTION_DAYS="${OPT_LOG_RETENTION:-30}"

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
# Re-run install.sh [--option value] to update.

PROJECT_DIR=${PROJECT_DIR}
VALIDATION_CMD="${VALIDATION_CMD}"
ALLOWED_TOOLS=${ALLOWED_TOOLS}
MAX_FILES=${MAX_FILES}
LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS}
INTERVAL=${INTERVAL}
ENVEOF
    echo "Created config: $CONFIG_FILE"
else
    # config 존재 — 지정된 옵션만 업데이트
    update_config() {
        local key="$1" val="$2"
        if grep -q "^${key}=" "$CONFIG_FILE"; then
            sed -i "s|^${key}=.*|${key}=${val}|" "$CONFIG_FILE"
        else
            echo "${key}=${val}" >> "$CONFIG_FILE"
        fi
    }
    update_config "PROJECT_DIR" "$PROJECT_DIR"
    update_config "VALIDATION_CMD" "\"$VALIDATION_CMD\""
    [[ -n "$OPT_INTERVAL" ]]      && update_config "INTERVAL" "$INTERVAL"
    [[ -n "$OPT_MAX_FILES" ]]     && update_config "MAX_FILES" "$MAX_FILES"
    [[ -n "$OPT_ALLOWED_TOOLS" ]] && update_config "ALLOWED_TOOLS" "$ALLOWED_TOOLS"
    [[ -n "$OPT_LOG_RETENTION" ]] && update_config "LOG_RETENTION_DAYS" "$LOG_RETENTION_DAYS"
    echo "Updated config: $CONFIG_FILE"
fi

# systemd timer 생성 (INTERVAL은 이미 옵션/기본값에서 설정됨)

rendered_timer="$(mktemp)"
trap 'rm -f "$rendered_timer"' EXIT
sed "s/%%INTERVAL%%/${INTERVAL}/g" "$TIMER_TEMPLATE" > "$rendered_timer"

install -m 0644 "$SERVICE_SOURCE" "$SERVICE_TARGET"
install -m 0644 "$rendered_timer" "$TIMER_TARGET"

systemctl --user daemon-reload
systemctl --user enable --now auto-debug.timer

echo ""
echo "=== Installation complete ==="
echo "  Project:      $PROJECT_DIR"
echo "  Validation:   $VALIDATION_CMD"
echo "  Interval:     every $INTERVAL"
echo "  Max files:    $MAX_FILES"
echo "  Allowed tools: $ALLOWED_TOOLS"
echo "  Config:       $CONFIG_FILE"
echo "  Logs:         journalctl --user -u auto-debug.service"
echo ""
echo "For 24/7 operation (survives logout):"
echo "  loginctl enable-linger \$(whoami)"
