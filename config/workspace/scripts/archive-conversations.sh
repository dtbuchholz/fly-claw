#!/usr/bin/env bash
# Archive conversation digests to the persistent workspace before session cleanup.
#
# Problem: When sessions reset (idle timeout, deploy), OpenClaw deletes session
# JSONL files and their conversation summaries. This erases reasoning history.
#
# Solution: Run extract-conversations.py to generate digests from current sessions,
# then copy the digests to a durable archive directory on the workspace volume.
# The archive survives session resets and deploys.
#
# Usage: Called by cron (pre-cleanup archival) or manually.
set -euo pipefail

OPENCLAW_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
SCRIPT_DIR="$(dirname "$0")"
ARCHIVE_DIR="$OPENCLAW_DIR/workspace/conversations"
CONVERSATIONS_DIR="$OPENCLAW_DIR/conversations"
SUMMARIES_DIR="$CONVERSATIONS_DIR/summaries"

echo "=== Conversation Archive ==="

# Step 1: Extract fresh conversation digests from session JSONL files
echo "Extracting conversation digests..."
python3 "$SCRIPT_DIR/extract-conversations.py" "$OPENCLAW_DIR"

# Step 2: Archive full transcripts to workspace (durable)
if [ -d "$CONVERSATIONS_DIR" ]; then
    mkdir -p "$ARCHIVE_DIR"
    # Copy only new/updated files (don't delete old archives — they're the whole point)
    find "$CONVERSATIONS_DIR" -name "*.md" -not -path "*/summaries/*" | while read -r src; do
        # Preserve agent subdirectory structure
        rel="${src#"$CONVERSATIONS_DIR/"}"
        dest="$ARCHIVE_DIR/$rel"
        dest_dir="$(dirname "$dest")"
        mkdir -p "$dest_dir"
        # Only copy if source is newer or dest doesn't exist
        if [ ! -f "$dest" ] || [ "$src" -nt "$dest" ]; then
            cp "$src" "$dest"
        fi
    done
    echo "Full transcripts archived to $ARCHIVE_DIR"
fi

# Step 3: Archive summaries to workspace (durable)
if [ -d "$SUMMARIES_DIR" ]; then
    mkdir -p "$ARCHIVE_DIR/summaries"
    find "$SUMMARIES_DIR" -name "*.md" | while read -r src; do
        rel="${src#"$SUMMARIES_DIR/"}"
        dest="$ARCHIVE_DIR/summaries/$rel"
        dest_dir="$(dirname "$dest")"
        mkdir -p "$dest_dir"
        if [ ! -f "$dest" ] || [ "$src" -nt "$dest" ]; then
            cp "$src" "$dest"
        fi
    done
    echo "Summaries archived to $ARCHIVE_DIR/summaries"
fi

# Step 4: Report
full_count=$(find "$ARCHIVE_DIR" -name "*.md" -not -path "*/summaries/*" 2>/dev/null | wc -l)
summary_count=$(find "$ARCHIVE_DIR/summaries" -name "*.md" 2>/dev/null | wc -l)
echo "Archive: $full_count transcripts, $summary_count summaries"
echo "=== Done ==="
