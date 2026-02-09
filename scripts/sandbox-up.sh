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

# Require API credentials (direct Anthropic key or OpenRouter key)
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${OPENROUTER_API_KEY:-}" ]; then
    echo "Error: Set ANTHROPIC_API_KEY or OPENROUTER_API_KEY in .env"
    exit 1
fi

# Generate gateway token if not set
if [ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]; then
    OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 16)
    echo "Generated gateway token: $OPENCLAW_GATEWAY_TOKEN"
    echo "  (Add OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN to .env to persist)"
fi

# Build env flags passed to every sandbox exec that runs OpenClaw
OC_ENV=(
    -e "TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}"
    -e "OPENCLAW_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}"
)
[ -n "${ANTHROPIC_API_KEY:-}" ]   && OC_ENV+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}")
[ -n "${OPENROUTER_API_KEY:-}" ]  && OC_ENV+=(-e "OPENROUTER_API_KEY=${OPENROUTER_API_KEY}")
[ -n "${OPENAI_API_KEY:-}" ]      && OC_ENV+=(-e "OPENAI_API_KEY=${OPENAI_API_KEY}")

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

# Copy config, injecting Telegram allowlist from env if set
if [ -n "${TELEGRAM_ALLOWED_IDS:-}" ]; then
    ALLOW_JSON=$(echo "$TELEGRAM_ALLOWED_IDS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R 'tonumber' | jq -s '.')
    jq --argjson ids "$ALLOW_JSON" '.channels.telegram.allowFrom = $ids' \
        "$ROOT_DIR/config/openclaw.json" > "$ROOT_DIR/.config-tmp.json"
    docker sandbox exec "$SANDBOX_NAME" \
        cp "$ROOT_DIR/.config-tmp.json" /home/agent/.openclaw/openclaw.json
    rm -f "$ROOT_DIR/.config-tmp.json"
else
    docker sandbox exec "$SANDBOX_NAME" \
        cp "$ROOT_DIR/config/openclaw.json" /home/agent/.openclaw/openclaw.json
fi

# Lock down permissions (doctor warns if too open)
docker sandbox exec "$SANDBOX_NAME" chmod 700 /home/agent/.openclaw
docker sandbox exec "$SANDBOX_NAME" chmod 600 /home/agent/.openclaw/openclaw.json

# Restore persisted state if available (survives make reset)
STATE_DIR="$ROOT_DIR/state"
if [ -d "$STATE_DIR" ]; then
    echo "Restoring persisted state..."
    # Restore workspace first (bot-generated files like IDENTITY.md, USER.md)
    if [ -d "$STATE_DIR/workspace" ]; then
        docker sandbox exec "$SANDBOX_NAME" \
            cp -r "$STATE_DIR/workspace" /home/agent/.openclaw/
    fi
    for dir in devices agents credentials cron telegram identity; do
        if [ -d "$STATE_DIR/$dir" ]; then
            docker sandbox exec "$SANDBOX_NAME" \
                cp -r "$STATE_DIR/$dir" /home/agent/.openclaw/
        fi
    done
fi

# Overwrite workspace with repo files (AGENTS.md, SOUL.md, skills always win)
docker sandbox exec "$SANDBOX_NAME" \
    bash -c "cp \"$ROOT_DIR/config/workspace/\"*.md /home/agent/.openclaw/workspace/ 2>/dev/null || true"
docker sandbox exec "$SANDBOX_NAME" \
    bash -c "cp -r \"$ROOT_DIR/config/workspace/skills/\"* /home/agent/.openclaw/workspace/skills/ 2>/dev/null || true"

# Run doctor --fix on first setup to initialize state dirs and finalize config
docker sandbox exec \
    "${OC_ENV[@]}" \
    "$SANDBOX_NAME" \
    openclaw doctor --fix > /dev/null 2>&1 || true

# Register API key in agent auth store
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    echo "Registering OpenRouter credentials..."
    docker sandbox exec \
        "${OC_ENV[@]}" \
        "$SANDBOX_NAME" \
        openclaw onboard --auth-choice apiKey --token-provider openrouter --token "$OPENROUTER_API_KEY" \
        > /dev/null 2>&1 || true
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    echo "Registering Anthropic credentials..."
    docker sandbox exec \
        "${OC_ENV[@]}" \
        "$SANDBOX_NAME" \
        openclaw onboard --auth-choice apiKey --token-provider anthropic --token "$ANTHROPIC_API_KEY" \
        > /dev/null 2>&1 || true
fi

# Apply network policy
echo "Applying network policy..."
"$SCRIPT_DIR/network-policy.sh" "$SANDBOX_NAME"

# Kill existing gateway (no-op on fresh sandboxes)
docker sandbox exec "$SANDBOX_NAME" pkill -f "openclaw gateway" 2>/dev/null || true
sleep 1

# Start the OpenClaw gateway
echo "Starting OpenClaw gateway..."
docker sandbox exec -d \
    "${OC_ENV[@]}" \
    "$SANDBOX_NAME" \
    bash -c 'openclaw gateway run --port 18789 > /tmp/openclaw-gateway.log 2>&1'

# Wait and check health (retry up to 10 times, 2s apart)
echo "Waiting for gateway to start..."
for i in $(seq 1 10); do
    sleep 2
    if docker sandbox exec \
        "${OC_ENV[@]}" \
        "$SANDBOX_NAME" \
        openclaw health > /dev/null 2>&1; then
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
