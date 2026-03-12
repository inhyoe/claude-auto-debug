#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# install.sh — claude-auto-debug 설치
# 사용법:
#   cd /path/to/my-project && bash install.sh          # 대화형 (기본)
#   bash install.sh -y                                  # 자동 (기본값 사용)
#   bash install.sh --interval 12h --max-files 5        # 특정 옵션 지정
#   원라인 설치는 setup.sh 사용 (README.md 참조)
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

require_arg() {
    if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "ERROR: $1 requires a value" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)        OPT_YES=true; shift ;;
        --interval)      require_arg "$@"; OPT_INTERVAL="$2"; shift 2 ;;
        --max-files)     require_arg "$@"; OPT_MAX_FILES="$2"; shift 2 ;;
        --allowed-tools) require_arg "$@"; OPT_ALLOWED_TOOLS="$2"; shift 2 ;;
        --validation)    require_arg "$@"; OPT_VALIDATION="$2"; shift 2 ;;
        --log-retention) require_arg "$@"; OPT_LOG_RETENTION="$2"; shift 2 ;;
        -h|--help)       show_help ;;
        -*)              echo "ERROR: Unknown option: $1" >&2; show_help ;;
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

# 기본값 결정: CLI 옵션 > 기존 config > 자동 감지/하드코딩 기본값
VALIDATION_CMD="${OPT_VALIDATION:-$(detect_validation_cmd "$PROJECT_DIR")}"
INTERVAL="${OPT_INTERVAL:-6h}"
MAX_FILES="${OPT_MAX_FILES:-3}"
ALLOWED_TOOLS="${OPT_ALLOWED_TOOLS:-Read,Edit,Write,Glob,Grep,Bash}"
LOG_RETENTION_DAYS="${OPT_LOG_RETENTION:-30}"

# Preserve existing config values for keys not overridden by CLI options
if [[ -f "$CONFIG_FILE" ]]; then
    [[ -z "$OPT_VALIDATION" ]]    && VALIDATION_CMD="$(read_config_value VALIDATION_CMD "$CONFIG_FILE" "$VALIDATION_CMD")"
    [[ -z "$OPT_INTERVAL" ]]      && INTERVAL="$(read_config_value INTERVAL "$CONFIG_FILE" "$INTERVAL")"
    [[ -z "$OPT_MAX_FILES" ]]     && MAX_FILES="$(read_config_value MAX_FILES "$CONFIG_FILE" "$MAX_FILES")"
    [[ -z "$OPT_ALLOWED_TOOLS" ]] && ALLOWED_TOOLS="$(read_config_value ALLOWED_TOOLS "$CONFIG_FILE" "$ALLOWED_TOOLS")"
    [[ -z "$OPT_LOG_RETENTION" ]] && LOG_RETENTION_DAYS="$(read_config_value LOG_RETENTION_DAYS "$CONFIG_FILE" "$LOG_RETENTION_DAYS")"
fi

# ── 대화형 설치 ─────────────────────────────────────────────────────────────
# 사용자에게 입력 받아서 기본값을 대체. Enter만 치면 기본값 유지.
prompt_value() {
    local label="$1" default="$2" result
    read -rp "  ${label} [${default}]: " result </dev/tty
    echo "${result:-$default}"
}

can_prompt() {
    [[ "$OPT_YES" = false ]] && { [[ -t 0 ]] || { [[ -e /dev/tty ]] && echo test < /dev/tty >/dev/null 2>&1; }; }
}

if can_prompt; then
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

# ── 입력 검증 (파일 생성 전에 실행) ──────────────────────────────────────────
# Validate INTERVAL format (systemd OnUnitActiveSec syntax: digits + optional unit)
if ! [[ "$INTERVAL" =~ ^[0-9]+[smhd]?$ ]]; then
    echo "ERROR: Invalid interval: '$INTERVAL'. Expected format: 30m, 1h, 6h, 1d" >&2
    exit 1
fi

if ! [[ "$MAX_FILES" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: MAX_FILES must be a positive integer, got: '$MAX_FILES'" >&2
    exit 1
fi

if ! [[ "$LOG_RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: LOG_RETENTION_DAYS must be a positive integer, got: '$LOG_RETENTION_DAYS'" >&2
    exit 1
fi

# ── 설치 실행 ───────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$SYSTEMD_USER_DIR"

echo ""
echo "Installing ..."

# bin/ + templates/ 복사 (기존 제거 후 복사 — 멱등성 보장)
rm -rf "$INSTALL_DIR/bin" "$INSTALL_DIR/templates"
cp -r "${SCRIPT_DIR}/bin" "$INSTALL_DIR/"
cp -r "${SCRIPT_DIR}/templates" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bin/auto-debug.sh"

# config.env 생성 또는 업데이트
# Values are written unquoted — load_config accepts KEY=value lines as-is.
# The regex parser stops at end of line, so no quoting needed for simple values.
write_val() {
    local key="$1" val="$2"
    # Values must not contain newlines (would break line-based parser)
    if [[ "$val" == *$'\n'* ]]; then
        echo "ERROR: Config value for $key contains newlines — not supported." >&2
        exit 1
    fi
    printf '%s=%s\n' "$key" "$val"
}

write_config() {
    # Preserve user-added supported keys (LOG_DIR, DEAD_LETTER_DIR, etc.)
    # that the installer does not manage directly.
    local extra_keys=""
    if [[ -f "$CONFIG_FILE" ]]; then
        local managed="PROJECT_DIR|VALIDATION_CMD|ALLOWED_TOOLS|MAX_FILES|LOG_RETENTION_DAYS|INTERVAL"
        extra_keys=$(grep -E '^[A-Z_]+=' "$CONFIG_FILE" \
            | grep -vE "^(${managed})=" \
            | grep -v '^#' || true)
    fi

    {
        echo '# Claude Auto-Debug — config'
        echo '# Re-run install.sh to update.'
        echo ''
        write_val PROJECT_DIR "$PROJECT_DIR"
        write_val VALIDATION_CMD "$VALIDATION_CMD"
        write_val ALLOWED_TOOLS "$ALLOWED_TOOLS"
        write_val MAX_FILES "$MAX_FILES"
        write_val LOG_RETENTION_DAYS "$LOG_RETENTION_DAYS"
        write_val INTERVAL "$INTERVAL"
    } > "$CONFIG_FILE"

    # Append preserved user keys
    if [[ -n "$extra_keys" ]]; then
        printf '\n# User-defined overrides (preserved across reinstall)\n' >> "$CONFIG_FILE"
        printf '%s\n' "$extra_keys" >> "$CONFIG_FILE"
    fi
}

if [[ ! -f "$CONFIG_FILE" ]]; then
    write_config
    echo "  Config created: $CONFIG_FILE"
else
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    write_config
    echo "  Config updated: $CONFIG_FILE (backup: ${CONFIG_FILE}.bak)"
fi

# systemd timer (INTERVAL already validated above — safe to substitute)
rendered_timer="$(mktemp)"
trap 'rm -f "$rendered_timer"' EXIT
sed "s|%%INTERVAL%%|${INTERVAL}|g" "$TIMER_TEMPLATE" > "$rendered_timer"

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
