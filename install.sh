#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${HOME}/.local/bin/claude-auto-debug"
CONFIG_DIR="${HOME}/.config/claude-auto-debug"
CONFIG_FILE="${CONFIG_DIR}/config.env"
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_SOURCE="${SCRIPT_DIR}/systemd/auto-debug.service"
TIMER_TEMPLATE="${SCRIPT_DIR}/systemd/auto-debug.timer.template"
SERVICE_TARGET="${SYSTEMD_USER_DIR}/auto-debug.service"
TIMER_TARGET="${SYSTEMD_USER_DIR}/auto-debug.timer"

# Read a key=value from config (handles quoting)
read_config_value() {
    local key="$1" file="$2" default="$3"
    local line
    line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n 1 || true)"
    if [[ -z "$line" ]]; then
        printf '%s\n' "$default"
        return
    fi
    local val="${line#*=}"
    # Strip surrounding quotes
    val="${val#\"}" ; val="${val%\"}"
    val="${val#\'}" ; val="${val%\'}"
    printf '%s\n' "$val"
}

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$SYSTEMD_USER_DIR"

# Install bin/ and templates/ to INSTALL_DIR
echo "Installing claude-auto-debug to $INSTALL_DIR ..."
cp -r "${SCRIPT_DIR}/bin" "$INSTALL_DIR/"
cp -r "${SCRIPT_DIR}/templates" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/bin/auto-debug.sh"

# Copy default config if it doesn't exist (never overwrite)
if [[ ! -f "$CONFIG_FILE" ]]; then
    install -m 0644 "${SCRIPT_DIR}/config.example.env" "$CONFIG_FILE"
    echo "Created default config at $CONFIG_FILE"
fi

# Read interval from config
INTERVAL="$(read_config_value "INTERVAL" "$CONFIG_FILE" "6h")"
[[ -z "$INTERVAL" ]] && INTERVAL="6h"

# Generate timer unit from template
rendered_timer="$(mktemp)"
trap 'rm -f "$rendered_timer"' EXIT
sed "s/%%INTERVAL%%/${INTERVAL}/g" "$TIMER_TEMPLATE" > "$rendered_timer"

# Install units
install -m 0644 "$SERVICE_SOURCE" "$SERVICE_TARGET"
install -m 0644 "$rendered_timer" "$TIMER_TARGET"

# Reload and enable
systemctl --user daemon-reload
systemctl --user enable --now auto-debug.timer

echo ""
echo "Installed:"
echo "  Scripts: $INSTALL_DIR/"
echo "  Service: $SERVICE_TARGET"
echo "  Timer:   $TIMER_TARGET"
echo ""
echo "For 24/7 operation outside an active login session, run:"
echo "  loginctl enable-linger \$(whoami)"
echo ""
echo "Config: $CONFIG_FILE"
echo "IMPORTANT: Set PROJECT_DIR in that file before the first run."
