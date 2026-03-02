#!/usr/bin/env bash
# State sync: commit and push /data/.openclaw directly to STATE_REPO.
# Runs as a background loop (entrypoint) and optionally via cron.
# Requires STATE_REPO to be set (typically via .env.secrets).
set -euo pipefail

OPENCLAW_DIR="/data/.openclaw"
STATE_REPO="${STATE_REPO:-}"

if [ -z "$STATE_REPO" ]; then
    echo "STATE_SYNC_SKIP: STATE_REPO not set"
    exit 0
fi

cd "$OPENCLAW_DIR"

# Initialize git repo if needed (first boot or fresh volume without restore)
if [ ! -d .git ]; then
    git init
    git remote add origin "$STATE_REPO"
fi

# Ensure remote URL is current (may change between deploys)
git remote set-url origin "$STATE_REPO" 2>/dev/null || true

# Auto-detect and ignore new nested repos in workspace/
for dir in workspace/*/; do
    [ -d "$dir" ] || continue
    dirname=$(basename "$dir")
    if [ -d "${dir}.git" ] && ! grep -qF "workspace/$dirname/" .gitignore 2>/dev/null; then
        echo "" >> .gitignore
        echo "# Auto-added by state-sync $(date -u +%Y-%m-%d)" >> .gitignore
        echo "workspace/$dirname/" >> .gitignore
        echo "Auto-ignored nested repo: workspace/$dirname/"
    fi
done

# Stage and commit
git add -A

if git diff --cached --quiet; then
    echo "STATE_SYNC_OK: no changes"
    exit 0
fi

CHANGED=$(git diff --cached --stat | tail -1)
git commit -m "Auto-sync: $CHANGED" --no-verify

if git push origin main 2>&1; then
    echo "STATE_SYNC_OK: pushed"
else
    echo "STATE_SYNC_ERROR: push failed"
    exit 1
fi
