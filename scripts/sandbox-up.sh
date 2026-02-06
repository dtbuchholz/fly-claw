#!/usr/bin/env bash
set -euo pipefail

SANDBOX_NAME="${1:-clawd}"
WORKSPACE_DIR="${2:-.}"
TEMPLATE_TAG="${3:-clawd-template:latest}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env if present
if [ -f "$ROOT_DIR/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$ROOT_DIR/.env"
    set +a
fi

# Require API key
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
    echo "Error: ANTHROPIC_API_KEY not set. Copy .env.example to .env and fill it in."
    exit 1
fi

# Generate gateway token if not set
if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
    OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 16)
    echo "Generated gateway token: $OPENCLAW_GATEWAY_TOKEN"
    echo "  (Add OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN to .env to persist)"
fi

# Check if sandbox already exists
if docker sandbox ls 2>/dev/null | grep -q "$SANDBOX_NAME"; then
    echo "Sandbox '$SANDBOX_NAME' already exists."
else
    echo "Creating sandbox '$SANDBOX_NAME'..."
    docker sandbox create \
        --name "$SANDBOX_NAME" \
        --load-local-template \
        -t "$TEMPLATE_TAG" \
        claude "$WORKSPACE_DIR"
fi

# Copy OpenClaw config into the sandbox
# The workspace syncs at the same absolute path, so files under $ROOT_DIR
# are available inside the sandbox. Copy from there to ~/.openclaw/.
echo "Syncing config..."
docker sandbox exec "$SANDBOX_NAME" mkdir -p /home/agent/.openclaw/workspace
docker sandbox exec "$SANDBOX_NAME" \
    cp "$ROOT_DIR/config/openclaw.json" /home/agent/.openclaw/openclaw.json
docker sandbox exec "$SANDBOX_NAME" \
    bash -c "cp \"$ROOT_DIR/config/workspace/\"*.md /home/agent/.openclaw/workspace/ 2>/dev/null || true"

# Restore persisted state if available (survives make reset)
STATE_DIR="$ROOT_DIR/state"
if [ -d "$STATE_DIR" ]; then
    echo "Restoring persisted state..."
    for dir in devices agents credentials cron; do
        if [ -d "$STATE_DIR/$dir" ]; then
            docker sandbox exec "$SANDBOX_NAME" \
                cp -r "$STATE_DIR/$dir" /home/agent/.openclaw/
        fi
    done
fi

# Run doctor --fix on first setup to initialize state dirs and finalize config
docker sandbox exec \
    -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" \
    -e "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}" \
    -e "OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}" \
    "$SANDBOX_NAME" \
    openclaw doctor --fix 2>/dev/null || true

# Apply network policy
echo "Applying network policy..."
"$SCRIPT_DIR/network-policy.sh" "$SANDBOX_NAME"

# Kill existing gateway (no-op on fresh sandboxes)
docker sandbox exec "$SANDBOX_NAME" pkill -f "openclaw gateway" 2>/dev/null || true
sleep 1

# Start the OpenClaw gateway
echo "Starting OpenClaw gateway..."
docker sandbox exec -d \
    -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" \
    -e "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}" \
    -e "OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}" \
    "$SANDBOX_NAME" \
    bash -c 'openclaw gateway run --port 18789 > /tmp/openclaw-gateway.log 2>&1'

# Wait and check health (retry up to 10 times, 2s apart)
echo "Waiting for gateway to start..."
for i in $(seq 1 10); do
    sleep 2
    if docker sandbox exec \
        -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" \
        -e "OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}" \
        "$SANDBOX_NAME" \
        openclaw health 2>/dev/null; then
        echo ""
        echo "=== Clawd is running ==="
        break
    fi
    if [ "$i" -eq 10 ]; then
        echo ""
        echo "Gateway may still be starting. Check: make logs"
    fi
done

echo "  Shell:  make shell"
echo "  Logs:   make logs"
echo "  Status: make status"
echo "  Stop:   make down"
