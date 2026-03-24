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

archive_full_transcripts() {
    if [ ! -d "$CONVERSATIONS_DIR" ]; then
        return
    fi

    mkdir -p "$ARCHIVE_DIR"
    find "$CONVERSATIONS_DIR" -type f -name "*.md" -not -path "$SUMMARIES_DIR/*" -print0 | while IFS= read -r -d '' src; do
        rel="${src#"$CONVERSATIONS_DIR/"}"
        dest="$ARCHIVE_DIR/$rel"
        dest_dir="$(dirname "$dest")"
        mkdir -p "$dest_dir"
        if [ ! -f "$dest" ] || [ "$src" -nt "$dest" ]; then
            cp "$src" "$dest"
        fi
    done
    echo "Full transcripts archived to $ARCHIVE_DIR"
}

archive_summaries() {
    if [ ! -d "$SUMMARIES_DIR" ]; then
        return
    fi

    mkdir -p "$ARCHIVE_DIR/summaries"
    find "$SUMMARIES_DIR" -type f -name "*.md" -print0 | while IFS= read -r -d '' src; do
        rel="${src#"$SUMMARIES_DIR/"}"
        dest="$ARCHIVE_DIR/summaries/$rel"
        dest_dir="$(dirname "$dest")"
        mkdir -p "$dest_dir"
        if [ ! -f "$dest" ] || [ "$src" -nt "$dest" ]; then
            cp "$src" "$dest"
        fi
    done
    echo "Summaries archived to $ARCHIVE_DIR/summaries"
}

echo "=== Conversation Archive ==="

# Step 1: Archive existing digests first (safe when sessions were already cleaned up)
echo "Archiving existing digests..."
archive_full_transcripts
archive_summaries

# Step 2: Extract fresh conversation digests from session JSONL files
echo "Extracting conversation digests..."
python3 "$SCRIPT_DIR/extract-conversations.py" "$OPENCLAW_DIR"

# Step 3: Archive fresh digests generated in this run
archive_full_transcripts
archive_summaries

# Step 4: Report
full_count=$(find "$ARCHIVE_DIR" -name "*.md" -not -path "*/summaries/*" 2>/dev/null | wc -l)
summary_count=$(find "$ARCHIVE_DIR/summaries" -name "*.md" 2>/dev/null | wc -l)
echo "Archive: $full_count transcripts, $summary_count summaries"
echo "=== Done ==="
