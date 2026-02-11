#!/usr/bin/env bash
set -euo pipefail

echo "=== Clawd Entrypoint ==="

# --- 1. Create persistent dirs ---
mkdir -p /data/.openclaw/workspace /data/logs

# --- 2. Symlink ~/.openclaw -> /data/.openclaw ---
ln -sfn /data/.openclaw /home/agent/.openclaw

# --- 3. Write secrets to file (sourced by agent user) ---
cat > /data/.env.secrets <<EOF
export OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-}"
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
EOF
chmod 600 /data/.env.secrets

# Add sourcing to .bashrc if not already there
if ! grep -q '.env.secrets' /home/agent/.bashrc 2>/dev/null; then
    echo '[ -f /data/.env.secrets ] && source /data/.env.secrets' >> /home/agent/.bashrc
fi

# --- 4. Copy base config ---
cp /opt/openclaw/openclaw.json /data/.openclaw/openclaw.json

# --- 5. Inject Telegram allowlist ---
if [ -n "${TELEGRAM_ALLOWED_IDS:-}" ]; then
    ALLOW_JSON=$(echo "$TELEGRAM_ALLOWED_IDS" | tr ',' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | jq -R 'tonumber' | jq -s '.')
    jq --argjson ids "$ALLOW_JSON" '.channels.telegram.allowFrom = $ids' \
        /data/.openclaw/openclaw.json > /data/.openclaw/openclaw.json.tmp \
        && mv /data/.openclaw/openclaw.json.tmp /data/.openclaw/openclaw.json
fi

# --- 6. Copy workspace files (repo versions always win) ---
cp /opt/openclaw/workspace/*.md /data/.openclaw/workspace/ 2>/dev/null || true
if [ -d /opt/openclaw/workspace/skills ]; then
    mkdir -p /data/.openclaw/workspace/skills
    cp -r /opt/openclaw/workspace/skills/* /data/.openclaw/workspace/skills/ 2>/dev/null || true
fi

# --- 7. Fix permissions ---
chmod 700 /data/.openclaw
chmod 600 /data/.openclaw/openclaw.json
chown -R agent:agent /data/.openclaw /data/logs /data/.env.secrets /home/agent/.bashrc

# --- 8. Tailscale (optional) ---
if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    echo "Starting Tailscale..."
    mkdir -p /var/run/tailscale /data/tailscale
    # Migrate old state file into statedir (one-time, from pre-statedir deploys)
    if [ -f /data/tailscaled.state ] && [ ! -f /data/tailscale/tailscaled.state ]; then
        mv /data/tailscaled.state /data/tailscale/tailscaled.state
    fi
    tailscaled --statedir=/data/tailscale --socket=/var/run/tailscale/tailscaled.sock &
    for i in $(seq 1 10); do
        tailscale status &>/dev/null && break
        sleep 1
    done
    TS_HOSTNAME="${FLY_APP_NAME:-clawd}"
    tailscale up --authkey="$TAILSCALE_AUTHKEY" --hostname="$TS_HOSTNAME" --ssh
    echo "Tailscale up: $(tailscale ip -4)"
fi

# --- 9. Doctor ---
echo "Running openclaw doctor..."
su - agent -c 'source /data/.env.secrets && openclaw doctor --fix' 2>&1 || true
# Doctor may disable the telegram plugin; force it back on
jq '.plugins.entries.telegram.enabled = true' /data/.openclaw/openclaw.json > /data/.openclaw/openclaw.json.tmp \
    && mv /data/.openclaw/openclaw.json.tmp /data/.openclaw/openclaw.json
chown agent:agent /data/.openclaw/openclaw.json
chmod 600 /data/.openclaw/openclaw.json

# --- 10. Onboard API credentials ---
echo "Registering API credentials..."
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    su - agent -c 'source /data/.env.secrets && openclaw onboard --auth-choice apiKey --token-provider openrouter --token "$OPENROUTER_API_KEY"' \
        2>&1 || true
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    su - agent -c 'source /data/.env.secrets && openclaw onboard --auth-choice apiKey --token-provider anthropic --token "$ANTHROPIC_API_KEY"' \
        2>&1 || true
fi

# --- 11. Start gateway (foreground, PID 1) ---
echo "=== Clawd Ready ==="
exec su - agent -c 'source /data/.env.secrets && openclaw gateway run --port 18789 2>&1 | tee /data/logs/gateway.log'
