#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# claude-auto-debug — Core Pipeline
# Runs Claude against a project in an isolated git worktree,
# validates the result, and merges or discards.
# ---------------------------------------------------------------------------

# ── Config loading (safe key-value parser — no arbitrary shell execution) ─────
load_config() {
    local file="$1" line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*($|#) ]] && continue
        [[ "$line" =~ ^([A-Z_]+)=(.*) ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        # Strip surrounding quotes (single or double)
        case "$val" in
            \'*\') val="${val:1:${#val}-2}" ;;
            \"*\") val="${val:1:${#val}-2}" ;;
        esac
        # Only accept known config keys (allowlist)
        case "$key" in
            PROJECT_DIR|VALIDATION_CMD|ALLOWED_TOOLS|MAX_FILES|\
            LOG_RETENTION_DAYS|INTERVAL|MAX_RECENT_COMMITS|\
            LOG_DIR|DEAD_LETTER_DIR|STATE_FILE|PROMPT_TEMPLATE|\
            DEFAULT_BRANCH)
                export "$key=$val"
                ;;
        esac
    done < "$file"
}

CONFIG_FILE="${CONFIG_FILE:-$HOME/.config/claude-auto-debug/config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
    load_config "$CONFIG_FILE"
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
WORKTREE_BASE="${XDG_RUNTIME_DIR:-/tmp}/claude-auto-debug-work"

# ── Globals set during runtime ──────────────────────────────────────────────
BRANCH_NAME=""
WORKTREE_PATH=""
DEFAULT_BRANCH=""
REMOTE_REF=""
HAS_REMOTE=true
VALIDATION_EXIT_CODE=0
LOG_FILE=""
LOCK_FD=9
LOCK_FILE="${HOME}/.config/claude-auto-debug/auto-debug.lock"
START_TS=""
ORIGINAL_PROJECT_DIR=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() { echo "[$(date -Iseconds)] $*"; }
err() { echo "[$(date -Iseconds)] ERROR: $*" >&2; }

# ---------------------------------------------------------------------------
# preflight — check required dependencies
# ---------------------------------------------------------------------------
preflight() {
    local missing=()
    command -v git      >/dev/null 2>&1 || missing+=("git")
    command -v claude   >/dev/null 2>&1 || missing+=("claude (Claude Code CLI)")
    command -v envsubst >/dev/null 2>&1 || missing+=("envsubst (install: apt install gettext-base)")
    command -v flock    >/dev/null 2>&1 || missing+=("flock (install: apt install util-linux)")

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing dependencies: ${missing[*]}"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# cleanup — runs on EXIT via trap
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    local proj="${ORIGINAL_PROJECT_DIR:-${PROJECT_DIR:-}}"

    if [[ -n "$WORKTREE_PATH" ]] && [[ -d "$WORKTREE_PATH" ]]; then
        git -C "$proj" worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
    fi

    if [[ -n "$BRANCH_NAME" ]] && git -C "$proj" rev-parse --verify "$BRANCH_NAME" &>/dev/null 2>&1; then
        git -C "$proj" branch -D "$BRANCH_NAME" 2>/dev/null || true
    fi

    return "$exit_code"
}

# ---------------------------------------------------------------------------
# detect_default_branch — find remote default branch (main/master/etc)
# ---------------------------------------------------------------------------
detect_default_branch() {
    cd "$PROJECT_DIR"

    # If DEFAULT_BRANCH was set via config, use it directly
    if [[ -n "${DEFAULT_BRANCH:-}" ]]; then
        if [[ "$HAS_REMOTE" = true ]] && git rev-parse --verify "origin/$DEFAULT_BRANCH" &>/dev/null 2>&1; then
            REMOTE_REF="origin/$DEFAULT_BRANCH"
        else
            REMOTE_REF="$DEFAULT_BRANCH"
        fi
        log "Using configured DEFAULT_BRANCH=$DEFAULT_BRANCH"
        return
    fi

    # Check if remote 'origin' exists
    if ! git remote get-url origin &>/dev/null; then
        log "Warning: No 'origin' remote. Using local branches only."
        DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
        REMOTE_REF="$DEFAULT_BRANCH"
        HAS_REMOTE=false
        return
    fi

    HAS_REMOTE=true

    # Try remote HEAD via local symbolic ref
    local ref
    ref=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)
    if [[ -n "$ref" ]]; then
        DEFAULT_BRANCH="${ref##*/}"
        REMOTE_REF="origin/$DEFAULT_BRANCH"
        return
    fi

    # Try resolving via ls-remote (authoritative remote query)
    local ls_ref
    ls_ref=$(git ls-remote --symref origin HEAD 2>/dev/null \
        | awk '/^ref:/{print $2}' | head -n1 || true)
    if [[ -n "$ls_ref" ]]; then
        DEFAULT_BRANCH="${ls_ref##*/}"
        REMOTE_REF="origin/$DEFAULT_BRANCH"
        return
    fi

    # Fallback: check common branch names
    for branch in main master; do
        if git rev-parse --verify "origin/$branch" &>/dev/null 2>&1; then
            DEFAULT_BRANCH="$branch"
            REMOTE_REF="origin/$branch"
            return
        fi
    done

    # All remote detection failed — abort rather than silently using current branch
    err "Cannot determine default branch from remote 'origin'. Set DEFAULT_BRANCH in config or run: git remote set-head origin --auto"
    exit 1
}

# ---------------------------------------------------------------------------
# setup — validate config, create dirs, start logging
# ---------------------------------------------------------------------------
setup() {
    if [[ -z "${PROJECT_DIR:-}" ]]; then
        err "PROJECT_DIR is not set. Set it in $CONFIG_FILE or as an environment variable."
        exit 1
    fi

    if [[ ! -d "$PROJECT_DIR" ]]; then
        err "PROJECT_DIR does not exist: $PROJECT_DIR"
        exit 1
    fi

    ORIGINAL_PROJECT_DIR="$PROJECT_DIR"

    mkdir -p "$LOG_DIR" "$DEAD_LETTER_DIR" "$(dirname "$STATE_FILE")"

    # Verify WORKTREE_BASE ownership (mitigate pre-created directory attacks)
    if [[ -d "$WORKTREE_BASE" ]]; then
        local dir_owner
        dir_owner=$(stat -c '%u' "$WORKTREE_BASE" 2>/dev/null || echo "")
        if [[ -n "$dir_owner" ]] && [[ "$dir_owner" != "$(id -u)" ]]; then
            err "WORKTREE_BASE owned by uid=$dir_owner (expected $(id -u)): $WORKTREE_BASE"
            exit 1
        fi
    fi
    mkdir -p -m 700 "$WORKTREE_BASE"

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

    detect_default_branch
    log "  DEFAULT_BRANCH   = $DEFAULT_BRANCH"
    log "  REMOTE_REF       = $REMOTE_REF"
}

# ---------------------------------------------------------------------------
# single_instance — acquire flock; exit 0 if already running
# ---------------------------------------------------------------------------
single_instance() {
    # Ensure lock directory exists (may not yet be created by setup on first run)
    mkdir -p "$(dirname "$LOCK_FILE")"

    # Reject symlinks to prevent symlink attacks on lock file
    if [[ -L "$LOCK_FILE" ]]; then
        err "Lock file is a symlink (possible attack): $LOCK_FILE"
        exit 1
    fi
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

    # Fetch upstream and fast-forward local branch if possible
    if [[ "$HAS_REMOTE" = true ]]; then
        if git fetch origin "refs/heads/$DEFAULT_BRANCH:refs/remotes/origin/$DEFAULT_BRANCH" 2>/dev/null; then
            # Ensure local DEFAULT_BRANCH ref exists (may only have remote-tracking ref)
            if ! git rev-parse --verify "refs/heads/$DEFAULT_BRANCH" &>/dev/null; then
                local remote_head
                remote_head=$(git rev-parse "$REMOTE_REF" 2>/dev/null || echo "")
                if [[ -n "$remote_head" ]]; then
                    git branch "$DEFAULT_BRANCH" "$remote_head" 2>/dev/null || true
                    log "Created local branch '$DEFAULT_BRANCH' from $REMOTE_REF"
                fi
            fi

            local local_sha remote_sha
            local_sha=$(git rev-parse "$DEFAULT_BRANCH" 2>/dev/null || echo "")
            remote_sha=$(git rev-parse "$REMOTE_REF" 2>/dev/null || echo "")
            if [[ -n "$remote_sha" ]] && [[ "$local_sha" != "$remote_sha" ]]; then
                if git merge-base --is-ancestor "$local_sha" "$remote_sha" 2>/dev/null; then
                    local current_branch ff_ok=true
                    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
                    if [[ "$current_branch" = "$DEFAULT_BRANCH" ]]; then
                        if ! git merge --ff-only "$REMOTE_REF" 2>/dev/null; then
                            log "Warning: Fast-forward failed (dirty worktree?). Using local HEAD."
                            ff_ok=false
                        fi
                    else
                        # Verify DEFAULT_BRANCH is not checked out in another worktree
                        if git worktree list --porcelain 2>/dev/null | grep -qF "branch refs/heads/$DEFAULT_BRANCH"; then
                            log "Warning: $DEFAULT_BRANCH is checked out in a worktree. Skipping ref update."
                            ff_ok=false
                        else
                            git update-ref "refs/heads/$DEFAULT_BRANCH" "$remote_sha" "$local_sha"
                        fi
                    fi
                    if [[ "$ff_ok" = true ]]; then
                        log "Fast-forwarded $DEFAULT_BRANCH to upstream (${remote_sha:0:8})"
                    fi
                fi
            fi
        else
            log "Warning: git fetch failed. Using local HEAD."
        fi
    fi

    # Always track LOCAL default branch head (consistent with worktree base and merge target)
    local current_sha
    current_sha=$(git rev-parse "$DEFAULT_BRANCH" 2>/dev/null || git rev-parse HEAD)

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

    [[ -d "$WORKTREE_PATH" ]] && rm -rf "$WORKTREE_PATH"

    log "Creating worktree at $WORKTREE_PATH (branch: $BRANCH_NAME) ..."
    git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" "$DEFAULT_BRANCH"

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

    # Compare against worktree base (DEFAULT_BRANCH) — catches committed, uncommitted, and untracked
    local changed_files
    changed_files=$(cd "$WORKTREE_PATH" && {
        git diff "$DEFAULT_BRANCH" --name-only
        git ls-files --others --exclude-standard
    } | sort -u | wc -l)

    if [[ "$changed_files" -eq 0 ]]; then
        log "No changes were made by Claude — no issues found."
        # Run validation to confirm the repo is healthy before marking as inspected
        log "Running validation on clean worktree to verify repo health ..."
        set +e
        bash -c "$VALIDATION_CMD" 2>&1
        local health_rc=$?
        set -e
        if [[ $health_rc -eq 0 ]]; then
            log "Repo health check PASSED. Marking SHA as inspected."
            echo "$CURRENT_SHA" > "$STATE_FILE"
        else
            log "Warning: Repo health check FAILED (exit $health_rc). SHA not marked — will retry next run."
        fi
        exit 0
    fi

    if [[ "$changed_files" -gt "$MAX_FILES" ]]; then
        err "Claude modified $changed_files files (limit: $MAX_FILES). Aborting."
        VALIDATION_EXIT_CODE=1
        return
    fi

    log "Changes detected ($changed_files files). Running validation: $VALIDATION_CMD"
    set +e
    bash -c "$VALIDATION_CMD" 2>&1
    VALIDATION_EXIT_CODE=$?
    set -e

    if [[ $VALIDATION_EXIT_CODE -eq 0 ]]; then
        log "Validation PASSED."
        # Ensure all changes are committed (prompt tells Claude NOT to commit)
        if [[ -n "$(git -C "$WORKTREE_PATH" status --porcelain)" ]]; then
            git -C "$WORKTREE_PATH" add -A
            set +e
            git -C "$WORKTREE_PATH" \
                -c user.name="Claude Auto-Debug" \
                -c user.email="noreply@auto-debug" \
                commit -m "fix(auto-debug): automated code quality fix

Co-Authored-By: Claude Auto-Debug <noreply@anthropic.com>"
            local commit_rc=$?
            set -e
            if [[ $commit_rc -ne 0 ]]; then
                err "Commit failed (exit $commit_rc). Saving diff to dead-letter before discard."
                local fail_diff="$DEAD_LETTER_DIR/commit-fail-$(date '+%Y%m%d-%H%M%S').patch"
                git -C "$WORKTREE_PATH" diff HEAD > "$fail_diff" 2>/dev/null || true
                VALIDATION_EXIT_CODE=1
                return
            fi
        fi
    else
        log "Validation FAILED (exit $VALIDATION_EXIT_CODE)."
    fi
}

# ---------------------------------------------------------------------------
# merge_or_discard — on pass: merge to default branch; on fail: dead-letter
# ---------------------------------------------------------------------------
merge_or_discard() {
    cd "$ORIGINAL_PROJECT_DIR"

    if [[ $VALIDATION_EXIT_CODE -eq 0 ]]; then
        log "Merging $BRANCH_NAME into $DEFAULT_BRANCH ..."

        # Remove worktree first so branch ref is free
        git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
        WORKTREE_PATH=""

        local target_sha base_sha
        target_sha=$(git rev-parse "$BRANCH_NAME")
        base_sha=$(git rev-parse "$DEFAULT_BRANCH")

        if ! git merge-base --is-ancestor "$base_sha" "$target_sha"; then
            err "Fast-forward merge not possible. Manual intervention required."
            exit 2
        fi

        # Merge strategy depends on whether DEFAULT_BRANCH is currently checked out
        local current_branch
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

        if [[ "$current_branch" = "$DEFAULT_BRANCH" ]]; then
            # Branch is checked out — use merge to keep working tree in sync
            if ! git merge --ff-only "$BRANCH_NAME"; then
                err "Fast-forward merge failed. Manual intervention required."
                exit 2
            fi
        else
            # Verify DEFAULT_BRANCH is not checked out in another worktree
            if git worktree list --porcelain 2>/dev/null | grep -qF "branch refs/heads/$DEFAULT_BRANCH"; then
                err "$DEFAULT_BRANCH is checked out in another worktree. Manual merge required."
                exit 2
            fi
            # Branch not checked out anywhere — update ref without touching working tree
            git update-ref "refs/heads/$DEFAULT_BRANCH" "$target_sha" "$base_sha"
        fi

        git branch -D "$BRANCH_NAME" 2>/dev/null || true
        BRANCH_NAME=""

        # Always track post-merge local HEAD (consistent with check_dedup)
        local merged_sha
        merged_sha=$(git rev-parse "$DEFAULT_BRANCH")
        echo "$merged_sha" > "$STATE_FILE"
        log "State updated: SHA ${merged_sha:0:8}"
        log "Success: changes merged into $DEFAULT_BRANCH."
    else
        log "Discarding failed branch. Copying log to dead-letter ..."
        local dead_log
        dead_log="$DEAD_LETTER_DIR/$(basename "$LOG_FILE")"
        cp "$LOG_FILE" "$dead_log"
        log "Dead-letter: $dead_log"
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
    find "$DEAD_LETTER_DIR" -maxdepth 1 \( -name "*.log" -o -name "*.patch" \) \
        -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
    preflight
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

    # Exit with non-zero if validation failed (surfaces failures in systemd/monitoring)
    if [[ $VALIDATION_EXIT_CODE -ne 0 ]]; then
        exit 1
    fi
}

main "$@"
