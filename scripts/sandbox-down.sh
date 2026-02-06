#!/usr/bin/env bash
set -euo pipefail

SANDBOX_NAME="${1:-clawd}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$ROOT_DIR/state"

if docker sandbox ls 2>/dev/null | grep -q "$SANDBOX_NAME"; then
    # Stop gateway cleanly before snapshotting state
    docker sandbox exec "$SANDBOX_NAME" pkill -f "openclaw gateway" 2>/dev/null || true
    sleep 1

    # Snapshot OpenClaw state to host before stopping
    echo "Snapshotting state..."
    mkdir -p "$STATE_DIR"
    for dir in devices agents credentials cron; do
        docker sandbox exec "$SANDBOX_NAME" \
            bash -c "[ -d /home/agent/.openclaw/$dir ] && cp -r /home/agent/.openclaw/$dir \"$STATE_DIR/\" || true"
    done

    echo "Stopping sandbox '$SANDBOX_NAME'..."
    docker sandbox stop "$SANDBOX_NAME"
    echo "Stopped."
else
    echo "Sandbox '$SANDBOX_NAME' not found."
fi
