#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# claude-auto-debug — Core Pipeline
# Runs Claude against a project in an isolated git worktree,
# validates the result, and merges or discards.
# ---------------------------------------------------------------------------

# ── Config loading ──────────────────────────────────────────────────────────
CONFIG_FILE="${CONFIG_FILE:-$HOME/.config/claude-auto-debug/config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# ── Default config values ───────────────────────────────────────────────────
: "${VALIDATION_CMD:=bash scripts/run-tests.sh}"
: "${ALLOWED_TOOLS:=Read,Edit,Write,Glob,Grep,Bash}"
: "${MAX_FILES:=3}"
: "${MAX_RECENT_COMMITS:=20}"
: "${LOG_DIR:=$HOME/.local/share/claude-auto-debug/logs}"
: "${DEAD_LETTER_DIR:=$HOME/.local/share/claude-auto-debug/dead-letter}"
: "${STATE_FILE:=$HOME/.config/claude-auto-debug/state}"
: "${LOG_RETENTION_DAYS:=30}"
: "${PROMPT_TEMPLATE:=$(cd "$(dirname "$0")" && pwd)/../templates/debug-prompt.md}"
WORKTREE_BASE="/tmp/claude-auto-debug-work"

# ── Globals set during runtime ──────────────────────────────────────────────
BRANCH_NAME=""
WORKTREE_PATH=""
VALIDATION_EXIT_CODE=0
LOG_FILE=""
LOCK_FD=9
LOCK_FILE="/tmp/claude-auto-debug.lock"
START_TS=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { echo "[$(date -Iseconds)] $*"; }
err() { echo "[$(date -Iseconds)] ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# cleanup — runs on EXIT via trap
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?

    # Remove worktree if it exists
    if [[ -n "$WORKTREE_PATH" ]] && [[ -d "$WORKTREE_PATH" ]]; then
        git -C "${PROJECT_DIR:-}" worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
    fi

    # Delete the work branch if it still exists
    if [[ -n "$BRANCH_NAME" ]] && git -C "${PROJECT_DIR:-}" rev-parse --verify "$BRANCH_NAME" &>/dev/null; then
        git -C "${PROJECT_DIR:-}" branch -D "$BRANCH_NAME" 2>/dev/null || true
    fi

    # flock releases automatically when fd closes on process exit
    return "$exit_code"
}

# ---------------------------------------------------------------------------
# setup — validate config, create dirs, start logging
# ---------------------------------------------------------------------------
setup() {
    if [[ -z "${PROJECT_DIR:-}" ]]; then
        err "PROJECT_DIR is not set. Set it in $CONFIG_FILE or as an environment variable."
        exit 1
    fi

    mkdir -p "$LOG_DIR" "$DEAD_LETTER_DIR" "$(dirname "$STATE_FILE")" "$WORKTREE_BASE"

    local ts
    ts=$(date '+%Y-%m-%d-%H%M%S')
    LOG_FILE="$LOG_DIR/${ts}.log"
    exec > >(tee -a "$LOG_FILE") 2>&1

    START_TS=$(date -Iseconds)
    log "=== claude-auto-debug started ==="
    log "  PROJECT_DIR      = $PROJECT_DIR"
    log "  VALIDATION_CMD   = $VALIDATION_CMD"
    log "  ALLOWED_TOOLS    = $ALLOWED_TOOLS"
    log "  MAX_FILES        = $MAX_FILES"
    log "  PROMPT_TEMPLATE  = $PROMPT_TEMPLATE"
    log "  LOG_FILE         = $LOG_FILE"
}

# ---------------------------------------------------------------------------
# single_instance — acquire flock; exit 0 if already running
# ---------------------------------------------------------------------------
single_instance() {
    eval "exec ${LOCK_FD}>'$LOCK_FILE'"
    if ! flock -n "$LOCK_FD"; then
        log "Another instance is already running. Exiting."
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# check_dedup — SHA-based: skip if HEAD hasn't changed since last success
# ---------------------------------------------------------------------------
check_dedup() {
    cd "$PROJECT_DIR"

    git fetch origin main 2>/dev/null || true
    local current_sha
    current_sha=$(git rev-parse origin/main)

    local last_sha
    last_sha=$(cat "$STATE_FILE" 2>/dev/null || echo "")

    if [[ -n "$last_sha" ]] && [[ "$current_sha" = "$last_sha" ]]; then
        log "No new commits since last successful run (SHA: ${current_sha:0:8}). Skipping."
        exit 0
    fi

    export CURRENT_SHA="$current_sha"
    export LAST_SHA="$last_sha"
}

# ---------------------------------------------------------------------------
# prepare_worktree — create isolated git worktree for auto-debug branch
# ---------------------------------------------------------------------------
prepare_worktree() {
    cd "$PROJECT_DIR"

    local ts
    ts=$(date '+%Y-%m-%d-%H%M%S')
    BRANCH_NAME="auto-debug/${ts}"
    WORKTREE_PATH="${WORKTREE_BASE}/${BRANCH_NAME//\//-}"

    # Clean up stale worktree path if it exists
    [[ -d "$WORKTREE_PATH" ]] && rm -rf "$WORKTREE_PATH"

    log "Creating worktree at $WORKTREE_PATH (branch: $BRANCH_NAME) ..."
    git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" origin/main

    log "Worktree ready."
}

# ---------------------------------------------------------------------------
# run_claude — build prompt via envsubst with explicit var list, invoke CLI
# ---------------------------------------------------------------------------
run_claude() {
    if [[ ! -f "$PROMPT_TEMPLATE" ]]; then
        err "Prompt template not found: $PROMPT_TEMPLATE"
        exit 3
    fi

    # Build RECENT_CHANGES from git log (SHA range or fallback)
    local recent
    if [[ -n "$LAST_SHA" ]]; then
        recent=$(git -C "$WORKTREE_PATH" log --oneline "${LAST_SHA}..${CURRENT_SHA}" 2>/dev/null || echo "(none)")
    else
        recent=$(git -C "$WORKTREE_PATH" log --oneline -"$MAX_RECENT_COMMITS" 2>/dev/null || echo "(first run)")
    fi

    export PROJECT_DIR="$WORKTREE_PATH"
    export VALIDATION_CMD
    export BRANCH_NAME
    export ALLOWED_TOOLS
    export RECENT_CHANGES="$recent"
    export MAX_FILES

    log "Running Claude in worktree (branch: $BRANCH_NAME) ..."

    # envsubst with EXPLICIT variable list — prevents accidental expansion
    local prompt
    prompt=$(envsubst '$PROJECT_DIR $VALIDATION_CMD $BRANCH_NAME $ALLOWED_TOOLS $RECENT_CHANGES $MAX_FILES' < "$PROMPT_TEMPLATE")

    cd "$WORKTREE_PATH"
    if ! claude -p "$prompt" --allowedTools "$ALLOWED_TOOLS" 2>&1; then
        err "Claude exited with a non-zero status."
        exit 3
    fi
}

# ---------------------------------------------------------------------------
# validate — check changes count, then run VALIDATION_CMD
# ---------------------------------------------------------------------------
validate() {
    cd "$WORKTREE_PATH"

    # Check if Claude made any changes
    local changed_files
    changed_files=$(git -C "$WORKTREE_PATH" diff HEAD --name-only | wc -l)

    if [[ "$changed_files" -eq 0 ]]; then
        log "No changes were made by Claude — no issues found."
        exit 0
    fi

    # Post-hoc MAX_FILES enforcement
    if [[ "$changed_files" -gt "$MAX_FILES" ]]; then
        err "Claude modified $changed_files files (limit: $MAX_FILES). Aborting."
        VALIDATION_EXIT_CODE=1
        return
    fi

    log "Changes detected ($changed_files files). Running validation: $VALIDATION_CMD"
    set +e
    eval "$VALIDATION_CMD" 2>&1
    VALIDATION_EXIT_CODE=$?
    set -e

    if [[ $VALIDATION_EXIT_CODE -eq 0 ]]; then
        log "Validation PASSED."
    else
        log "Validation FAILED (exit $VALIDATION_EXIT_CODE)."
    fi
}

# ---------------------------------------------------------------------------
# merge_or_discard — on pass: merge to main; on fail: dead-letter
# ---------------------------------------------------------------------------
merge_or_discard() {
    cd "$PROJECT_DIR"

    if [[ $VALIDATION_EXIT_CODE -eq 0 ]]; then
        log "Merging $BRANCH_NAME into main ..."

        # Remove worktree first so branch is not checked out
        git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
        WORKTREE_PATH=""

        if ! git merge --ff-only "$BRANCH_NAME"; then
            err "Fast-forward merge failed. Manual intervention required."
            exit 2
        fi

        # Delete merged branch
        git branch -D "$BRANCH_NAME" 2>/dev/null || true
        BRANCH_NAME=""

        # Update state with current SHA (write-on-success-only)
        echo "$CURRENT_SHA" > "$STATE_FILE"
        log "State updated: SHA ${CURRENT_SHA:0:8}"
        log "Success: changes merged into main."
    else
        log "Discarding failed branch. Copying log to dead-letter ..."
        local dead_log
        dead_log="$DEAD_LETTER_DIR/$(basename "$LOG_FILE")"
        cp "$LOG_FILE" "$dead_log"
        log "Dead-letter: $dead_log"

        # Worktree + branch cleaned up by cleanup trap
        log "Branch will be discarded by cleanup trap."
    fi
}

# ---------------------------------------------------------------------------
# cleanup_old_logs — remove logs older than LOG_RETENTION_DAYS
# ---------------------------------------------------------------------------
cleanup_old_logs() {
    log "Cleaning up logs older than ${LOG_RETENTION_DAYS} days ..."
    find "$LOG_DIR" -maxdepth 1 -name "*.log" \
        -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
    find "$DEAD_LETTER_DIR" -maxdepth 1 -name "*.log" \
        -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    single_instance
    trap cleanup EXIT

    setup
    check_dedup
    prepare_worktree
    run_claude
    validate
    merge_or_discard
    cleanup_old_logs

    log "=== claude-auto-debug finished ==="
    log "  Started  : $START_TS"
    log "  Finished : $(date -Iseconds)"
}

main "$@"
