#!/usr/bin/env bash
set -euo pipefail

SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_TARGET="${SYSTEMD_USER_DIR}/auto-debug.service"
TIMER_TARGET="${SYSTEMD_USER_DIR}/auto-debug.timer"
CONFIG_DIR="${HOME}/.config/claude-auto-debug"

# Stop and disable timer (ignore errors if not active)
systemctl --user disable --now auto-debug.timer >/dev/null 2>&1 || true

# Remove unit files
rm -f "$SERVICE_TARGET" "$TIMER_TARGET"

# Reload daemon
systemctl --user daemon-reload

echo "Removed user units:"
echo "  $SERVICE_TARGET"
echo "  $TIMER_TARGET"
echo ""
echo "Config preserved at ${CONFIG_DIR}/"
echo "Logs available via: journalctl --user -u auto-debug.service"
