#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/data/state-repo"
OPENCLAW_DIR="/data/.openclaw"
STATE_REPO="${STATE_REPO:?STATE_REPO not set}"

# Ensure clone exists
if [ ! -d "$REPO_DIR/.git" ]; then
    git clone "$STATE_REPO" "$REPO_DIR"
fi

cd "$REPO_DIR"
git pull --rebase --autostash || git pull --no-rebase

# Sync state files (respects existing .gitignore in the repo)
rsync -a --delete "$OPENCLAW_DIR/workspace/" "$REPO_DIR/workspace/"
cp "$OPENCLAW_DIR/openclaw.json" "$REPO_DIR/openclaw.json"
rsync -a --delete "$OPENCLAW_DIR/cron/" "$REPO_DIR/cron/" 2>/dev/null || true
rsync -a --delete --exclude='*.lock' "$OPENCLAW_DIR/agents/" "$REPO_DIR/agents/" 2>/dev/null || true

# Commit + push only if changes
git add -A
if ! git diff --cached --quiet; then
    git commit -m "state: sync $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    git push
fi
