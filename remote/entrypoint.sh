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
export SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-}"
export SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
EOF
chmod 600 /data/.env.secrets

# Forward any additional Fly secrets not listed above.
# Skips system, infrastructure, and entrypoint-consumed env vars.
_extra_secrets=""
while IFS='=' read -r key _; do
    grep -q "^export ${key}=" /data/.env.secrets 2>/dev/null && continue
    case "$key" in
        PATH|HOME|HOSTNAME|SHELL|USER|PWD|OLDPWD|SHLVL|TERM|LANG|LC_*|_) continue ;;
        DEBIAN_FRONTEND|PUPPETEER_*|CHROMIUM_*|NODE_OPTIONS) continue ;;
        FLY_*|PRIMARY_REGION|LOG_LEVEL) continue ;;
        TAILSCALE_AUTHKEY|TELEGRAM_ALLOWED_IDS|TELEGRAM_GROUP_IDS|STATE_REPO|STATE_SYNC_INTERVAL|CRON_MODEL) continue ;;
    esac
    _extra_secrets+="$(printf 'export %s="%s"\n' "$key" "${!key}")"$'\n'
done < <(env)
[ -n "$_extra_secrets" ] && printf '%s' "$_extra_secrets" >> /data/.env.secrets

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
    .channels.slack.enabled = true |
    .plugins.entries.telegram.enabled = true |
    .plugins.entries.slack.enabled = true |
    .agents.defaults.sandbox.mode = "off" |
    .browser.enabled = true |
    .browser.headless = true |
    .browser.noSandbox = true |
    .browser.attachOnly = true |
    .browser.executablePath = "/usr/bin/chromium" |
    .browser.defaultProfile = "openclaw" |
    .browser.profiles.openclaw.cdpPort = 18800 |
    .browser.profiles.openclaw.color = "#FF4500"
' /data/.openclaw/openclaw.json > /data/.openclaw/openclaw.json.tmp \
    && mv /data/.openclaw/openclaw.json.tmp /data/.openclaw/openclaw.json

# --- 5. Inject Telegram allowlist + group access ---
if [ -n "${TELEGRAM_ALLOWED_IDS:-}" ]; then
    ALLOW_JSON=$(echo "$TELEGRAM_ALLOWED_IDS" | tr ',' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | jq -R 'tonumber' | jq -s '.')
    jq --argjson ids "$ALLOW_JSON" '.channels.telegram.allowFrom = $ids' \
        /data/.openclaw/openclaw.json > /data/.openclaw/openclaw.json.tmp \
        && mv /data/.openclaw/openclaw.json.tmp /data/.openclaw/openclaw.json
fi

if [ -n "${TELEGRAM_GROUP_IDS:-}" ]; then
    # Build groups object: { "-100xxx": { "groupPolicy": "open", "requireMention": false }, ... }
    GROUPS_JSON=$(echo "$TELEGRAM_GROUP_IDS" | tr ',' '\n' \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
        | jq -R '{ (.): { "groupPolicy": "open", "requireMention": false } }' \
        | jq -s 'add')
    jq --argjson groups "$GROUPS_JSON" '
        .channels.telegram.groups = (.channels.telegram.groups // {} | . * $groups)
    ' /data/.openclaw/openclaw.json > /data/.openclaw/openclaw.json.tmp \
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
if compgen -G '/opt/openclaw/workspace/scripts/*' >/dev/null; then
    mkdir -p /data/.openclaw/workspace/scripts
    for f in /opt/openclaw/workspace/scripts/*; do
        dest="/data/.openclaw/workspace/scripts/$(basename "$f")"
        [ -e "$dest" ] || cp "$f" "$dest"
    done
fi

# --- 6b. Seed default cron jobs (first boot only — state-repo restore overrides if present) ---
if [ ! -f /data/.openclaw/cron/jobs.json ]; then
    echo "Seeding default cron jobs..."
    mkdir -p /data/.openclaw/cron
    cp /opt/openclaw/cron/jobs.json /data/.openclaw/cron/jobs.json
    CRON_MODEL="${CRON_MODEL:-openrouter/anthropic/claude-sonnet-4.5}"
    jq --arg model "$CRON_MODEL" '.jobs |= map(.payload.model = $model)' \
        /data/.openclaw/cron/jobs.json > /tmp/cron.tmp && mv /tmp/cron.tmp /data/.openclaw/cron/jobs.json
fi

# --- 7. Persist git + SSH config ---
mkdir -p /data/.ssh /data/.gnupg /data/git
[ -f /data/git/config ] || touch /data/git/config
ln -sfn /data/.ssh /home/agent/.ssh
ln -sfn /data/git/config /home/agent/.gitconfig
ln -sfn /data/.gnupg /home/agent/.gnupg

# --- 8. Restore from state repo (fresh volume only) ---
# If STATE_REPO is set and no MEMORY.md exists, this is likely a fresh volume.
# Clone the state repo to /data/state-repo (persistent, reused by sync loop)
# and restore workspace + config to recover from volume loss.
if [ -n "${STATE_REPO:-}" ] && [ ! -f /data/.openclaw/workspace/MEMORY.md ]; then
    echo "Fresh volume detected + STATE_REPO set — restoring state..."
    # Ensure GitHub host key is trusted for clone
    su - agent -c 'ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null' || true
    if su - agent -c "git clone '${STATE_REPO}' /data/state-repo" 2>&1; then
        # Restore workspace
        if [ -d /data/state-repo/workspace ]; then
            cp -r /data/state-repo/workspace/* /data/.openclaw/workspace/ 2>/dev/null || true
            echo "✓ Workspace restored from state repo"
        fi
        # Restore config (root level, matching repo layout)
        if [ -f /data/state-repo/openclaw.json ]; then
            cp /data/state-repo/openclaw.json /data/.openclaw/openclaw.json
            echo "✓ Config restored from state repo"
        fi
        # Restore cron jobs
        if [ -d /data/state-repo/cron ]; then
            mkdir -p /data/.openclaw/cron
            cp -r /data/state-repo/cron/* /data/.openclaw/cron/ 2>/dev/null || true
            echo "✓ Cron jobs restored from state repo"
        fi
        # Restore agent sessions
        if [ -d /data/state-repo/agents ]; then
            mkdir -p /data/.openclaw/agents
            cp -r /data/state-repo/agents/* /data/.openclaw/agents/ 2>/dev/null || true
            echo "✓ Agent data restored from state repo"
        fi
    else
        echo "! State repo clone failed — continuing with defaults"
    fi
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

# --- 13. Start Chromium for browser automation (headless, background) ---
echo "Starting Chromium (headless)..."
BROWSER_DATA_DIR=/data/.openclaw/browser/openclaw/user-data
mkdir -p "$BROWSER_DATA_DIR"
chown -R agent:agent /data/.openclaw/browser
su - agent -c "chromium --headless --no-sandbox --disable-gpu \
    --remote-debugging-port=18800 \
    --user-data-dir='$BROWSER_DATA_DIR' \
    about:blank" &>/data/logs/chromium.log &
CHROMIUM_PID=$!
# Wait for CDP to be ready
for _retry in $(seq 1 10); do
    if curl -s http://127.0.0.1:18800/json/version >/dev/null 2>&1; then
        echo "Chromium ready (PID $CHROMIUM_PID, CDP on :18800)"
        break
    fi
    sleep 1
done

# --- 13.5. State sync loop (background, optional) ---
if [ -n "${STATE_REPO:-}" ]; then
    SYNC_INTERVAL="${STATE_SYNC_INTERVAL:-1800}"
    # Ensure persistent clone exists (step 8 only runs on fresh volumes)
    if [ ! -d /data/state-repo/.git ]; then
        su - agent -c 'ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null' || true
        su - agent -c "git clone '${STATE_REPO}' /data/state-repo" 2>&1 || true
    fi
    chown -R agent:agent /data/state-repo 2>/dev/null || true
    echo "Starting state sync loop (interval: ${SYNC_INTERVAL}s)..."
    (
        while sleep "$SYNC_INTERVAL"; do
            su - agent -c 'source /data/.env.secrets && /usr/local/bin/state-sync.sh' \
                >>/data/logs/state-sync.log 2>&1 || true
        done
    ) &
fi

# --- 13.7. Pre-warm QMD embeddings (background) ---
# Downloads GGUF models (~2GB, cached on /data volume) and generates embeddings
# so the first memory_search isn't slow. Delayed to let the gateway create collections first.
echo "Scheduling QMD embedding warm-up..."
(
    sleep 30
    su - agent -c 'source /data/.env.secrets && qmd embed' \
        >>/data/logs/qmd-warmup.log 2>&1 || true
) &

# --- 14. Start gateway (foreground, PID 1) ---
echo "=== Clawd Ready ==="
exec su - agent -c 'source /data/.env.secrets && openclaw gateway run --port 18789 2>&1 | tee /data/logs/gateway.log'
