#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# install.sh — claude-auto-debug 설치
# 사용법:
#   cd /path/to/my-project && bash install.sh          # 대화형 (기본)
#   bash install.sh -y                                  # 자동 (기본값 사용)
#   bash install.sh --interval 12h --max-files 5        # 특정 옵션 지정
#   bash <(curl ...) -y                                 # 원라인 자동 설치
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
OPT_YES=false

show_help() {
    cat <<'HELPEOF'
Usage: install.sh [OPTIONS] [PROJECT_DIR]

Modes:
  (default)              대화형 설치 — 각 옵션을 확인/수정
  -y, --yes              자동 설치 — 기본값 또는 지정 옵션 사용

Options:
  --interval TIME        실행 주기 (기본: 6h). 예: 30m, 1h, 6h, 1d
  --max-files N          1회 최대 수정 파일 수 (기본: 3)
  --allowed-tools LIST   Claude 허용 도구 (기본: Read,Edit,Write,Glob,Grep,Bash)
  --validation CMD       검증 명령어 (기본: 자동 감지)
  --log-retention DAYS   로그 보존 기간 (기본: 30)
  -h, --help             도움말

Examples:
  cd ~/my-project && bash install.sh           # 대화형
  cd ~/my-project && bash install.sh -y        # 자동
  bash install.sh --interval 12h ~/my-project  # 특정 옵션
HELPEOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)        OPT_YES=true; shift ;;
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

# ── PROJECT_DIR ─────────────────────────────────────────────────────────────
if [[ -n "$OPT_PROJECT" ]]; then
    PROJECT_DIR="$(cd "$OPT_PROJECT" && pwd)"
else
    PROJECT_DIR="$(pwd)"
fi

if [[ "$PROJECT_DIR" = "$SCRIPT_DIR" ]]; then
    echo "ERROR: 대상 프로젝트 디렉토리에서 실행하세요." >&2
    echo "  cd /path/to/your-project" >&2
    echo "  bash $SCRIPT_DIR/install.sh" >&2
    exit 1
fi

if ! git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null; then
    echo "ERROR: $PROJECT_DIR 는 git 저장소가 아닙니다." >&2
    exit 1
fi

# ── 자동 감지 ───────────────────────────────────────────────────────────────
detect_validation_cmd() {
    local dir="$1"
    if [[ -f "$dir/scripts/run-tests.sh" ]]; then
        echo "bash scripts/run-tests.sh"
    elif [[ -f "$dir/Makefile" ]] && grep -q '^test:' "$dir/Makefile" 2>/dev/null; then
        echo "make test"
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
        echo "echo 'No validation command detected — skipping'"
    fi
}

# 기본값 결정: CLI 옵션 > 자동 감지/하드코딩 기본값
VALIDATION_CMD="${OPT_VALIDATION:-$(detect_validation_cmd "$PROJECT_DIR")}"
INTERVAL="${OPT_INTERVAL:-6h}"
MAX_FILES="${OPT_MAX_FILES:-3}"
ALLOWED_TOOLS="${OPT_ALLOWED_TOOLS:-Read,Edit,Write,Glob,Grep,Bash}"
LOG_RETENTION_DAYS="${OPT_LOG_RETENTION:-30}"

# ── 대화형 설치 ─────────────────────────────────────────────────────────────
# 사용자에게 입력 받아서 기본값을 대체. Enter만 치면 기본값 유지.
prompt_value() {
    local label="$1" default="$2" result
    read -rp "  ${label} [${default}]: " result </dev/tty
    echo "${result:-$default}"
}

if [[ "$OPT_YES" = false ]] && [[ -t 0 || -e /dev/tty ]]; then
    echo ""
    echo "╔══════════════════════════════════════════╗"
    echo "║   claude-auto-debug installer            ║"
    echo "╚══════════════════════════════════════════╝"
    echo ""
    echo "  Project:    $PROJECT_DIR"
    echo "  Validation: $VALIDATION_CMD (auto-detected)"
    echo ""

    read -rp "설정을 변경하시겠습니까? [y/N]: " configure </dev/tty
    if [[ "$configure" =~ ^[yY] ]]; then
        echo ""
        INTERVAL="$(prompt_value "실행 주기 (예: 30m, 1h, 6h, 1d)" "$INTERVAL")"
        MAX_FILES="$(prompt_value "1회 최대 수정 파일 수" "$MAX_FILES")"
        VALIDATION_CMD="$(prompt_value "검증 명령어" "$VALIDATION_CMD")"
        ALLOWED_TOOLS="$(prompt_value "Claude 허용 도구" "$ALLOWED_TOOLS")"
        LOG_RETENTION_DAYS="$(prompt_value "로그 보존 기간 (일)" "$LOG_RETENTION_DAYS")"
    fi

    echo ""
    echo "── 설치 요약 ──────────────────────────────"
    echo "  Project:       $PROJECT_DIR"
    echo "  Validation:    $VALIDATION_CMD"
    echo "  Interval:      $INTERVAL"
    echo "  Max files:     $MAX_FILES"
    echo "  Allowed tools: $ALLOWED_TOOLS"
    echo "  Log retention: ${LOG_RETENTION_DAYS}d"
    echo ""

    read -rp "진행하시겠습니까? [Y/n]: " confirm </dev/tty
    if [[ "$confirm" =~ ^[nN] ]]; then
        echo "설치를 취소했습니다."
        exit 0
    fi
fi

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

# ── 설치 실행 ───────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$SYSTEMD_USER_DIR"

echo ""
echo "Installing ..."

# bin/ + templates/ 복사
cp -r "${SCRIPT_DIR}/bin" "$INSTALL_DIR/"
cp -r "${SCRIPT_DIR}/templates" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bin/auto-debug.sh"

# config.env 생성 또는 업데이트
update_config() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "$CONFIG_FILE"
    else
        echo "${key}=${val}" >> "$CONFIG_FILE"
    fi
}

if [[ ! -f "$CONFIG_FILE" ]]; then
    cat > "$CONFIG_FILE" << ENVEOF
# Claude Auto-Debug — config
# Re-run install.sh to update.

PROJECT_DIR=${PROJECT_DIR}
VALIDATION_CMD="${VALIDATION_CMD}"
ALLOWED_TOOLS=${ALLOWED_TOOLS}
MAX_FILES=${MAX_FILES}
LOG_RETENTION_DAYS=${LOG_RETENTION_DAYS}
INTERVAL=${INTERVAL}
ENVEOF
    echo "  Config created: $CONFIG_FILE"
else
    update_config "PROJECT_DIR" "$PROJECT_DIR"
    update_config "VALIDATION_CMD" "\"$VALIDATION_CMD\""
    update_config "INTERVAL" "$INTERVAL"
    update_config "MAX_FILES" "$MAX_FILES"
    update_config "ALLOWED_TOOLS" "$ALLOWED_TOOLS"
    update_config "LOG_RETENTION_DAYS" "$LOG_RETENTION_DAYS"
    echo "  Config updated: $CONFIG_FILE"
fi

# systemd timer
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
echo "  Config:       $CONFIG_FILE"
echo "  Logs:         journalctl --user -u auto-debug.service"
echo ""
echo "For 24/7 operation (survives logout):"
echo "  loginctl enable-linger \$(whoami)"
