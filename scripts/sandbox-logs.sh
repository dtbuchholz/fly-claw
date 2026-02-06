#!/usr/bin/env bash
set -euo pipefail

SANDBOX_NAME="${1:-clawd}"

if ! docker sandbox ls 2>/dev/null | grep -q "$SANDBOX_NAME"; then
    echo "Sandbox '$SANDBOX_NAME' not found. Run 'make up' first."
    exit 1
fi

docker sandbox exec "$SANDBOX_NAME" tail -f /tmp/openclaw-gateway.log
