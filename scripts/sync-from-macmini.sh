#!/bin/bash
# sync-from-macmini.sh — Pull session files from Mac Mini (10.0.10.100)
# Usage: ./scripts/sync-from-macmini.sh [--dry-run]

set -euo pipefail

REMOTE="bing@10.0.10.100"
DRY_RUN=""
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN="--dry-run"
    echo "=== DRY RUN ==="
fi

RSYNC_OPTS="-avz --ignore-existing --progress $DRY_RUN"

sync_source() {
    local label="$1"
    local remote_path="$2"
    local local_path="$3"
    echo ""
    echo "━━━ $label ━━━"
    mkdir -p "$local_path"
    rsync $RSYNC_OPTS "${REMOTE}:${remote_path}/" "${local_path}/"
}

echo "Syncing from Mac Mini ($REMOTE)..."
echo "Local files will NOT be overwritten (--ignore-existing)"

# Claude Code — JSONL files, ~102M
sync_source "Claude Code" "~/.claude/projects" "$HOME/.claude/projects"

# Codex — session files, ~25M
sync_source "Codex" "~/.codex/sessions" "$HOME/.codex/sessions"

# Gemini CLI — JSONL files, ~12K
sync_source "Gemini CLI" "~/.gemini/tmp" "$HOME/.gemini/tmp"

# Antigravity — protobuf conversations, ~60M
sync_source "Antigravity" "~/.gemini/antigravity/conversations" "$HOME/.gemini/antigravity/conversations"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Done! Restart Engram to index new sessions."
