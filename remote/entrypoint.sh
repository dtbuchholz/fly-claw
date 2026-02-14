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
export GH_TOKEN="${GH_TOKEN:-}"
export BRAVE_API_KEY="${BRAVE_API_KEY:-}"
EOF
chmod 600 /data/.env.secrets

# Add sourcing to .bashrc if not already there
if ! grep -q '.env.secrets' /home/agent/.bashrc 2>/dev/null; then
    echo '[ -f /data/.env.secrets ] && source /data/.env.secrets' >> /home/agent/.bashrc
fi

# --- 4. Seed config on first boot, then patch infra keys ---
if [ ! -f /data/.openclaw/openclaw.json ]; then
    echo "First boot: seeding config from image"
    cp /opt/openclaw/openclaw.json /data/.openclaw/openclaw.json
fi

# Patch infra-level keys (safe to run every deploy — leaves agent-managed keys untouched)
jq '
    .gateway.port = 18789 |
    .gateway.bind = "loopback" |
    .gateway.mode = "local" |
    .gateway.auth.mode = "token" |
    .channels.telegram.enabled = true |
    .channels.telegram.dmPolicy = "allowlist" |
    .plugins.entries.telegram.enabled = true |
    .agents.defaults.sandbox.mode = "off"
' /data/.openclaw/openclaw.json > /data/.openclaw/openclaw.json.tmp \
    && mv /data/.openclaw/openclaw.json.tmp /data/.openclaw/openclaw.json

# --- 5. Inject Telegram allowlist ---
if [ -n "${TELEGRAM_ALLOWED_IDS:-}" ]; then
    ALLOW_JSON=$(echo "$TELEGRAM_ALLOWED_IDS" | tr ',' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | jq -R 'tonumber' | jq -s '.')
    jq --argjson ids "$ALLOW_JSON" '.channels.telegram.allowFrom = $ids' \
        /data/.openclaw/openclaw.json > /data/.openclaw/openclaw.json.tmp \
        && mv /data/.openclaw/openclaw.json.tmp /data/.openclaw/openclaw.json
fi

# --- 6. Seed workspace files (first boot only — never overwrite agent changes) ---
if compgen -G '/opt/openclaw/workspace/*.md' >/dev/null; then
    for f in /opt/openclaw/workspace/*.md; do
        dest="/data/.openclaw/workspace/$(basename "$f")"
        [ -f "$dest" ] || cp "$f" "$dest"
    done
fi
if compgen -G '/opt/openclaw/workspace/skills/*' >/dev/null; then
    mkdir -p /data/.openclaw/workspace/skills
    for f in /opt/openclaw/workspace/skills/*; do
        dest="/data/.openclaw/workspace/skills/$(basename "$f")"
        [ -e "$dest" ] || cp -r "$f" "$dest"
    done
fi

# --- 7. Persist git + SSH config ---
mkdir -p /data/.ssh /data/.gnupg /data/git
[ -f /data/git/config ] || touch /data/git/config
ln -sfn /data/.ssh /home/agent/.ssh
ln -sfn /data/git/config /home/agent/.gitconfig
ln -sfn /data/.gnupg /home/agent/.gnupg

# --- 8. Restore from state repo (fresh volume only) ---
# If STATE_REPO is set and no MEMORY.md exists, this is likely a fresh volume.
# Clone the state repo and restore workspace + config to recover from volume loss.
if [ -n "${STATE_REPO:-}" ] && [ ! -f /data/.openclaw/workspace/MEMORY.md ]; then
    echo "Fresh volume detected + STATE_REPO set — restoring workspace..."
    # Ensure GitHub host key is trusted for clone
    su - agent -c 'ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null' || true
    if su - agent -c "git clone '${STATE_REPO}' /tmp/state-restore" 2>&1; then
        if [ -d /tmp/state-restore/workspace ]; then
            cp -r /tmp/state-restore/workspace/* /data/.openclaw/workspace/ 2>/dev/null || true
            echo "✓ Workspace restored from state repo"
        fi
        if [ -f /tmp/state-restore/config/openclaw.json ]; then
            cp /tmp/state-restore/config/openclaw.json /data/.openclaw/openclaw.json
            echo "✓ Config restored from state repo"
        fi
    else
        echo "! State repo clone failed — continuing with defaults"
    fi
    rm -rf /tmp/state-restore
fi

# --- 9. Fix permissions ---
chmod 700 /data/.openclaw /data/.ssh /data/.gnupg /data/git
chmod 600 /data/.openclaw/openclaw.json
[ -s /data/.ssh/id_ed25519 ] && chmod 600 /data/.ssh/id_ed25519
chown -R agent:agent /data/.openclaw /data/.ssh /data/git /data/.gnupg /data/logs /data/.env.secrets /home/agent/.bashrc

# --- 10. Tailscale (optional) ---
if [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    echo "Starting Tailscale..."
    mkdir -p /var/run/tailscale /data/tailscale
    # Migrate old state file into statedir (one-time, from pre-statedir deploys)
    if [ -f /data/tailscaled.state ] && [ ! -f /data/tailscale/tailscaled.state ]; then
        mv /data/tailscaled.state /data/tailscale/tailscaled.state
    fi
    # Clean up legacy state file (already migrated)
    [ -f /data/tailscaled.state ] && [ -d /data/tailscale ] && rm -f /data/tailscaled.state
    tailscaled --statedir=/data/tailscale --socket=/var/run/tailscale/tailscaled.sock &
    for _retry in $(seq 1 10); do
        tailscale status &>/dev/null && break
        sleep 1
    done
    TS_HOSTNAME="${FLY_APP_NAME:-clawd}"
    tailscale up --authkey="$TAILSCALE_AUTHKEY" --hostname="$TS_HOSTNAME" --ssh
    echo "Tailscale up: $(tailscale ip -4)"
fi

# --- 11. Doctor ---
echo "Running openclaw doctor..."
su - agent -c 'source /data/.env.secrets && openclaw doctor --fix' 2>&1 || true
# Doctor may disable the telegram plugin; force it back on
jq '.plugins.entries.telegram.enabled = true' /data/.openclaw/openclaw.json > /data/.openclaw/openclaw.json.tmp \
    && mv /data/.openclaw/openclaw.json.tmp /data/.openclaw/openclaw.json
chown agent:agent /data/.openclaw/openclaw.json
chmod 600 /data/.openclaw/openclaw.json

# --- 12. Onboard API credentials ---
echo "Registering API credentials..."
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    # shellcheck disable=SC2016 # $OPENROUTER_API_KEY expands inside su subshell via sourced .env.secrets
    su - agent -c 'source /data/.env.secrets && openclaw onboard --auth-choice apiKey --token-provider openrouter --token "$OPENROUTER_API_KEY"' \
        2>&1 || true
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    # shellcheck disable=SC2016 # $ANTHROPIC_API_KEY expands inside su subshell via sourced .env.secrets
    su - agent -c 'source /data/.env.secrets && openclaw onboard --auth-choice apiKey --token-provider anthropic --token "$ANTHROPIC_API_KEY"' \
        2>&1 || true
fi

# --- 13. Start gateway (foreground, PID 1) ---
echo "=== Clawd Ready ==="
exec su - agent -c 'source /data/.env.secrets && openclaw gateway run --port 18789 2>&1 | tee /data/logs/gateway.log'
