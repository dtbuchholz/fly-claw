#!/usr/bin/env bash
set -euo pipefail

SANDBOX_NAME="${1:-clawd}"

# Load .env if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
if [ -f "$ROOT_DIR/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$ROOT_DIR/.env"
    set +a
fi

echo "=== Sandbox ==="
if docker sandbox ls 2>/dev/null | grep -q "$SANDBOX_NAME"; then
    docker sandbox inspect "$SANDBOX_NAME" 2>/dev/null || docker sandbox ls
    echo ""
    echo "=== Gateway ==="
    docker sandbox exec \
        -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}" \
        "$SANDBOX_NAME" \
        openclaw health 2>/dev/null \
        && echo "Gateway: healthy" \
        || echo "Gateway: not responding"
else
    echo "Sandbox '$SANDBOX_NAME' not found."
fi
