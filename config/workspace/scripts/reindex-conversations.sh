#!/usr/bin/env bash
# Extract conversation digests from OpenClaw session JSONL files and trigger QMD reindex.
# Run periodically (e.g., daily cron or after state-sync) to keep conversations searchable.
set -euo pipefail

OPENCLAW_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
SCRIPT_DIR="$(dirname "$0")"

echo "Extracting conversation digests..."
python3 "$SCRIPT_DIR/extract-conversations.py" "$OPENCLAW_DIR"

echo "Triggering QMD update..."
if command -v qmd >/dev/null 2>&1; then
    qmd update 2>&1 || echo "QMD update warning (non-fatal)"
    qmd embed 2>&1 || echo "QMD embed warning (non-fatal)"
    echo "QMD reindex complete."
else
    echo "QMD not available — skipping reindex (digests still written to disk)."
fi
