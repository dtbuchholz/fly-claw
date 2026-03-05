#!/usr/bin/env bash
set -euo pipefail

echo "=== Clawd Entrypoint ==="

STATE_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
MAX_CONCURRENT=4
# Backward-compatible GitHub token naming: prefer GITHUB_TOKEN, fall back to GH_TOKEN.
GH_TOKEN_EFFECTIVE="${GITHUB_TOKEN:-${GH_TOKEN:-}}"

# --- 1. Create persistent dirs ---
mkdir -p /data/.openclaw/workspace /data/.openclaw/extensions /data/.claude /data/.codex /data/.cache /data/logs

# --- 1.5. Persist node-llama-cpp builds across deploys ---
# Without this, QMD recompiles llama.cpp on every deploy (~minutes on shared CPUs).
LLAMA_CPP_DIR="/usr/lib/node_modules/@tobilu/qmd/node_modules/node-llama-cpp"
PERSIST_BUILDS="/data/.cache/node-llama-cpp-builds"
mkdir -p "$PERSIST_BUILDS"
if [ -d "$LLAMA_CPP_DIR" ]; then
    # If Docker image has a fresh build, seed the persistent cache
    if [ -d "$LLAMA_CPP_DIR/localBuilds" ] && [ "$(ls -A "$LLAMA_CPP_DIR/localBuilds" 2>/dev/null)" ]; then
        cp -rn "$LLAMA_CPP_DIR/localBuilds/"* "$PERSIST_BUILDS/" 2>/dev/null || true
    fi
    # Symlink localBuilds to persistent volume
    rm -rf "$LLAMA_CPP_DIR/localBuilds"
    ln -sfn "$PERSIST_BUILDS" "$LLAMA_CPP_DIR/localBuilds"
    echo "✓ node-llama-cpp builds linked to persistent volume"
    if [ "$(find "$PERSIST_BUILDS" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" -gt 0 ]; then
        echo "✓ node-llama-cpp cache detected in $PERSIST_BUILDS"
    else
        echo "Warning: node-llama-cpp cache is empty; first successful qmd embed will populate it."
    fi
fi

# --- 2. Symlink persistent dirs into agent home ---
ln -sfn /data/.openclaw /home/agent/.openclaw
ln -sfn /data/.claude /home/agent/.claude
ln -sfn /data/.codex /home/agent/.codex
ln -sfn /data/.cache /home/agent/.cache

# --- 3. Write secrets to file (sourced by agent user) ---
cat > /data/.env.secrets <<EOF
export OPENROUTER_API_KEY="${OPENROUTER_API_KEY:-}"
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
export CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
export OPENAI_API_KEY="${OPENAI_API_KEY:-}"
export TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-}"
export GH_TOKEN="${GH_TOKEN_EFFECTIVE:-}"
export GITHUB_TOKEN="${GITHUB_TOKEN:-}"
export GITHUB_USERNAME="${GITHUB_USERNAME:-}"
export GITHUB_EMAIL="${GITHUB_EMAIL:-}"
export BRAVE_API_KEY="${BRAVE_API_KEY:-}"
export SLACK_APP_TOKEN="${SLACK_APP_TOKEN:-}"
export SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
export CLAUDE_CONFIG_REPO="${CLAUDE_CONFIG_REPO:-}"
export CODEX_CONFIG_REPO="${CODEX_CONFIG_REPO:-}"
export AGENT_EMAIL_ADDRESS="${AGENT_EMAIL_ADDRESS:-}"
export AGENT_EMAIL_PASSWORD="${AGENT_EMAIL_PASSWORD:-}"
export AGENT_TWITTER_EMAIL="${AGENT_TWITTER_EMAIL:-}"
export AGENT_TWITTER_PASSWORD="${AGENT_TWITTER_PASSWORD:-}"
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
        TAILSCALE_AUTHKEY|TELEGRAM_ALLOWED_IDS|TELEGRAM_GROUP_IDS|CRON_MODEL|CRON_SYNC_MODE|FORCE_AGENT_CONFIG) continue ;;
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
jq --argjson max_concurrent "$MAX_CONCURRENT" '
    .gateway.port = 18789 |
    .gateway.bind = "loopback" |
    .gateway.mode = "local" |
    .gateway.auth.mode = "token" |
    .channels.telegram.enabled = true |
    .channels.slack.enabled = true |
    .plugins.entries.telegram.enabled = true |
    .plugins.entries.slack.enabled = true |
    .agents.defaults.sandbox.mode = "off" |
    .agents.defaults.maxConcurrent = $max_concurrent |
    .browser.enabled = true |
    .browser.headless = true |
    .browser.noSandbox = true |
    .browser.attachOnly = true |
    .browser.executablePath = "/usr/bin/chromium" |
    .browser.defaultProfile = "openclaw" |
    .browser.profiles.openclaw.cdpPort = 18800 |
    .browser.profiles.openclaw.color = "#FF4500" |
    .plugins.entries.acpx.enabled = true |
    .plugins.entries.acpx.config.permissionMode = "approve-all" |
    .tools.sessions.visibility = "agent" |
    .tools.media.audio.enabled = true |
    .tools.media.audio.models = [{"provider": "openai", "model": "gpt-4o-mini-transcribe", "capabilities": ["audio"]}] |
    .acp.enabled = true |
    .acp.backend = "acpx" |
    .acp.dispatch.enabled = true
' /data/.openclaw/openclaw.json > /data/.openclaw/openclaw.json.tmp \
    && mv /data/.openclaw/openclaw.json.tmp /data/.openclaw/openclaw.json

# Select default models based on available credentials.
DEFAULT_PRIMARY_MODEL="anthropic/claude-opus-4-6"
DEFAULT_CRON_MODEL="anthropic/claude-sonnet-4-5"
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -n "${OPENROUTER_API_KEY:-}" ]; then
    DEFAULT_PRIMARY_MODEL="openrouter/openai/gpt-5.2-codex"
    DEFAULT_CRON_MODEL="openrouter/openai/gpt-5.2-codex"
    echo "No Anthropic credentials found; defaulting primary/cron model to $DEFAULT_PRIMARY_MODEL"
fi

# Always: set primary model to match available credentials.
jq --arg model "$DEFAULT_PRIMARY_MODEL" '.agents.defaults.model.primary = $model' \
    /data/.openclaw/openclaw.json > /data/.openclaw/openclaw.json.tmp \
    && mv /data/.openclaw/openclaw.json.tmp /data/.openclaw/openclaw.json

# Patch agent-level settings (model aliases, context budget, compaction, session reset).
# Only runs on explicit opt-in (FORCE_AGENT_CONFIG=1) or after state-repo restore,
# so agent customizations made on the VM aren't overwritten on normal deploys.
_patch_agent_settings() {
    local target="$1"
    echo "Applying agent config patch..."
    jq --arg model "$DEFAULT_PRIMARY_MODEL" --argjson max_concurrent "$MAX_CONCURRENT" '
        .agents.defaults.model.primary = $model |
        .agents.defaults.maxConcurrent = $max_concurrent |
        .agents.defaults.models = {
            "anthropic/claude-sonnet-4-5": { "alias": "Sonnet" },
            "anthropic/claude-opus-4-6": { "alias": "Opus" },
            "anthropic/claude-haiku-4-5": { "alias": "Haiku" },
            "openrouter/openai/gpt-5.2-codex": { "alias": "Codex" }
        } |
        .agents.defaults.contextTokens = 200000 |
        .agents.defaults.compaction.mode = "default" |
        .agents.defaults.compaction.reserveTokensFloor = 30000 |
        .agents.defaults.compaction.memoryFlush.enabled = true |
        .agents.defaults.compaction.memoryFlush.softThresholdTokens = 4000 |
        .session.reset = { "mode": "idle", "idleMinutes": 60 }
    ' "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"
}

_patch_cron_models() {
    local target="$1"
    local model="$2"
    jq --arg model "$model" '
        .jobs |= map(
            if (.payload.model // "" | test("^openrouter/")) then .payload.model = $model else . end
        )
    ' "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"
}

_sync_cron_jobs_upsert_by_id() {
    local target="$1"
    local seed="$2"
    jq -s '
        .[0] as $live |
        .[1] as $seed |
        ($live.jobs // []) as $liveJobs |
        ($seed.jobs // []) as $seedJobs |
        ($seedJobs | map(select(.id != null)) | map({key: .id, value: .}) | from_entries) as $seedById |
        ($liveJobs | map(.id)) as $liveIds |
        ($liveJobs | map(if (.id != null and ($seedById[.id] != null)) then $seedById[.id] else . end)) as $merged |
        ($seedJobs | map(. as $job | select($job.id != null and (($liveIds | index($job.id)) == null)))) as $missing |
        $live | .jobs = ($merged + $missing)
    ' "$target" "$seed" > "${target}.tmp" && mv "${target}.tmp" "$target"
}

_sync_cron_jobs() {
    local target="$1"
    local seed="$2"
    local mode="$3"
    local model="$4"
    if [ ! -f "$target" ]; then
        return 0
    fi
    case "$mode" in
        off)
            echo "Cron sync mode: off (leaving existing jobs unchanged)"
            ;;
        models-only)
            echo "Cron sync mode: models-only"
            _patch_cron_models "$target" "$model"
            ;;
        upsert-by-id)
            echo "Cron sync mode: upsert-by-id (repo IDs overwrite, custom jobs preserved)"
            _sync_cron_jobs_upsert_by_id "$target" "$seed"
            _patch_cron_models "$target" "$model"
            ;;
        replace-all)
            echo "Cron sync mode: replace-all (overwriting live cron config from repo)"
            cp "$seed" "$target"
            _patch_cron_models "$target" "$model"
            ;;
        *)
            echo "Warning: unknown CRON_SYNC_MODE='$mode' (expected off|models-only|upsert-by-id|replace-all). Using models-only."
            _patch_cron_models "$target" "$model"
            ;;
    esac
}

CRON_SYNC_MODE="${CRON_SYNC_MODE:-off}"
CRON_MODEL_EFFECTIVE="${CRON_MODEL:-$DEFAULT_CRON_MODEL}"
if [ "${FORCE_AGENT_CONFIG:-}" = "1" ]; then
    _patch_agent_settings /data/.openclaw/openclaw.json
fi
# Optionally sync cron definitions outside FORCE_AGENT_CONFIG flow.
# This enables targeted cron updates without forcing all agent config defaults.
if [ "${CRON_SYNC_MODE:-off}" != "off" ]; then
    _sync_cron_jobs /data/.openclaw/cron/jobs.json /opt/openclaw/cron/jobs.json "$CRON_SYNC_MODE" "$CRON_MODEL_EFFECTIVE"
fi

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
    CRON_MODEL="${CRON_MODEL:-$DEFAULT_CRON_MODEL}"
    # Replace the default Sonnet model with CRON_MODEL; jobs that specify a different model are kept as-is.
    SEED_MODEL="anthropic/claude-sonnet-4-5"
    jq --arg model "$CRON_MODEL" --arg seed "$SEED_MODEL" '
        .jobs |= map(if .payload.model == $seed then .payload.model = $model else . end)
    ' /data/.openclaw/cron/jobs.json > /tmp/cron.tmp && mv /tmp/cron.tmp /data/.openclaw/cron/jobs.json
fi

# --- 6c. Seed Claude Code config + OpenClaw workspace skills ---
# Always clones; merges new items without overwriting existing ones.
# shellcheck disable=SC2016 # Intentional single quotes — GH_TOKEN expands at runtime
CLAUDE_CONFIG_REPO="${CLAUDE_CONFIG_REPO:-https://github.com/dtbuchholz/claude-config.git}"
_claude_url="$CLAUDE_CONFIG_REPO"
[ -n "${GH_TOKEN:-}" ] && _claude_url="${_claude_url/https:\/\/github.com/https://x-access-token:${GH_TOKEN}@github.com}"
if su - agent -c "git clone '${_claude_url}' /tmp/claude-seed" 2>&1; then
    # Claude Code CLI config (~/.claude/)
    [ -f /tmp/claude-seed/settings.json ] && [ ! -f /data/.claude/settings.json ] \
        && cp /tmp/claude-seed/settings.json /data/.claude/
    for _dir in hooks skills agents; do
        if [ -d "/tmp/claude-seed/$_dir" ]; then
            mkdir -p "/data/.claude/$_dir"
            for _item in /tmp/claude-seed/"$_dir"/*; do
                [ -e "$_item" ] || continue
                _dest="/data/.claude/$_dir/$(basename "$_item")"
                [ -e "$_dest" ] || cp -r "$_item" "$_dest"
            done
        fi
    done
    # OpenClaw workspace skills (same repo, dual purpose)
    if [ -d /tmp/claude-seed/skills ]; then
        mkdir -p /data/.openclaw/workspace/skills
        for _item in /tmp/claude-seed/skills/*; do
            [ -e "$_item" ] || continue
            _dest="/data/.openclaw/workspace/skills/$(basename "$_item")"
            [ -e "$_dest" ] || cp -r "$_item" "$_dest"
        done
    fi
    echo "✓ Claude Code config + workspace skills synced"
fi
rm -rf /tmp/claude-seed

# --- 6d. Seed Codex CLI config ---
CODEX_CONFIG_REPO="${CODEX_CONFIG_REPO:-https://github.com/dtbuchholz/codex-config.git}"
_codex_url="$CODEX_CONFIG_REPO"
[ -n "${GH_TOKEN:-}" ] && _codex_url="${_codex_url/https:\/\/github.com/https://x-access-token:${GH_TOKEN}@github.com}"
if su - agent -c "git clone '${_codex_url}' /tmp/codex-seed" 2>&1; then
    # Codex CLI config (~/.codex/)
    [ -f /tmp/codex-seed/config.toml.template ] && [ ! -f /data/.codex/config.toml ] \
        && cp /tmp/codex-seed/config.toml.template /data/.codex/config.toml
    for _dir in hooks skills agents policy; do
        if [ -d "/tmp/codex-seed/$_dir" ]; then
            mkdir -p "/data/.codex/$_dir"
            for _item in /tmp/codex-seed/"$_dir"/*; do
                [ -e "$_item" ] || continue
                _dest="/data/.codex/$_dir/$(basename "$_item")"
                [ -e "$_dest" ] || cp -r "$_item" "$_dest"
            done
        fi
    done
    echo "✓ Codex config synced"
fi
rm -rf /tmp/codex-seed

# --- 7. Persist git + SSH config ---
mkdir -p /data/.ssh /data/.gnupg /data/git
[ -f /data/git/config ] || touch /data/git/config
ln -sfn /data/.ssh /home/agent/.ssh
ln -sfn /data/git/config /home/agent/.gitconfig
ln -sfn /data/.gnupg /home/agent/.gnupg

# --- 8. Restore from state repo (fresh volume only) ---
# If STATE_REPO is set and no MEMORY.md exists, this is likely a fresh volume.
# Clone the state repo directly into /data/.openclaw — the same dir used for
# ongoing sync (no separate /data/state-repo clone).
_state_restored=0
if [ -n "${STATE_REPO:-}" ] && [ ! -f /data/.openclaw/workspace/MEMORY.md ]; then
    echo "Fresh volume detected + STATE_REPO set — restoring state..."
    su - agent -c 'ssh-keyscan github.com >> ~/.ssh/known_hosts 2>/dev/null' || true
    # Clone into a temp dir, then move contents into /data/.openclaw
    # (can't clone directly into non-empty dir)
    if su - agent -c "git clone '${STATE_REPO}' /tmp/state-restore" 2>&1; then
        # Move git history into /data/.openclaw, then hard-reset to restore tracked files
        if mv /tmp/state-restore/.git /data/.openclaw/.git; then
            _state_restored=1
            (cd /data/.openclaw && git reset --hard HEAD 2>/dev/null) || true
            echo "✓ State restored from repo (git history preserved)"
        else
            echo "! Failed to move .git into /data/.openclaw — continuing with defaults"
        fi
    else
        echo "! State repo clone failed — continuing with defaults"
    fi
    rm -rf /tmp/state-restore
fi

# Re-apply agent settings after state-repo restore (restored state may have stale config).
# Also re-apply model.primary since restore overwrites it.
if [ "$_state_restored" -eq 1 ]; then
    jq --arg model "$DEFAULT_PRIMARY_MODEL" '.agents.defaults.model.primary = $model' \
        /data/.openclaw/openclaw.json > /data/.openclaw/openclaw.json.tmp \
        && mv /data/.openclaw/openclaw.json.tmp /data/.openclaw/openclaw.json
    _patch_agent_settings /data/.openclaw/openclaw.json
    # Apply cron sync policy after state restore (restored cron may be stale).
    _sync_cron_jobs /data/.openclaw/cron/jobs.json /opt/openclaw/cron/jobs.json "${CRON_SYNC_MODE:-models-only}" "$DEFAULT_CRON_MODEL"
fi

# --- 9. Fix permissions ---
chmod 700 /data/.openclaw /data/.claude /data/.codex /data/.ssh /data/.gnupg /data/git
chmod 600 /data/.openclaw/openclaw.json
[ -s /data/.ssh/id_ed25519 ] && chmod 600 /data/.ssh/id_ed25519
chown -R agent:agent /data/.openclaw /data/.claude /data/.codex /data/.cache /data/.ssh /data/git /data/.gnupg /data/logs /data/.env.secrets /home/agent/.bashrc
# acpx plugin dir must be owned by agent — OpenClaw blocks world-writable extensions
chown -R agent:agent /usr/lib/node_modules/openclaw/extensions/acpx/ 2>/dev/null || true

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
# Doctor may disable plugins; force telegram + acpx back on
jq '
    .plugins.entries.telegram.enabled = true |
    .plugins.entries.acpx.enabled = true |
    .plugins.entries.acpx.config.permissionMode = "approve-all"
' /data/.openclaw/openclaw.json > /data/.openclaw/openclaw.json.tmp \
    && mv /data/.openclaw/openclaw.json.tmp /data/.openclaw/openclaw.json
chown agent:agent /data/.openclaw/openclaw.json
chmod 600 /data/.openclaw/openclaw.json

# --- 11b. Enable internal hooks ---
echo "Enabling hooks..."
su - agent -c 'source /data/.env.secrets && openclaw hooks enable session-memory' 2>&1 || true
su - agent -c 'source /data/.env.secrets && openclaw hooks enable boot-md' 2>&1 || true

# --- 11.5. Validate config ---
echo "Validating OpenClaw config..."
if command -v openclaw >/dev/null 2>&1; then
    openclaw config validate 2>&1 || echo "! Config validation warning (non-fatal on older versions)"
fi

# --- 12. Onboard API credentials ---
echo "Registering API credentials..."
# Primary: Anthropic subscription (setup-token) > Anthropic API key
anthropic_registered=0
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    # shellcheck disable=SC2016 # $CLAUDE_CODE_OAUTH_TOKEN expands inside su subshell via sourced .env.secrets
    if su - agent -c 'source /data/.env.secrets && openclaw onboard --auth-choice setupToken --token-provider anthropic --token "$CLAUDE_CODE_OAUTH_TOKEN"' \
        2>&1; then
        anthropic_registered=1
    else
        echo "Warning: setup-token auth failed; trying Anthropic API key if available."
    fi
fi
if [ "$anthropic_registered" -eq 0 ] && [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    # shellcheck disable=SC2016 # $ANTHROPIC_API_KEY expands inside su subshell via sourced .env.secrets
    if su - agent -c 'source /data/.env.secrets && openclaw onboard --auth-choice apiKey --token-provider anthropic --token "$ANTHROPIC_API_KEY"' \
        2>&1; then
        anthropic_registered=1
    else
        echo "Warning: Anthropic API key onboarding failed."
    fi
fi
# Secondary: OpenRouter (always register if present, for non-Anthropic models)
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    # shellcheck disable=SC2016 # $OPENROUTER_API_KEY expands inside su subshell via sourced .env.secrets
    su - agent -c 'source /data/.env.secrets && openclaw onboard --auth-choice apiKey --token-provider openrouter --token "$OPENROUTER_API_KEY"' \
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
# Commits and pushes /data/.openclaw directly (no separate clone).
# STATE_REPO and STATE_SYNC_INTERVAL are available via .env.secrets.
if [ -n "${STATE_REPO:-}" ]; then
    SYNC_INTERVAL="${STATE_SYNC_INTERVAL:-1800}"
    echo "Starting state sync loop (interval: ${SYNC_INTERVAL}s)..."
    (
        while sleep "$SYNC_INTERVAL"; do
            su - agent -c 'source /data/.env.secrets && /usr/local/bin/state-sync.sh' \
                >>/data/logs/state-sync.log 2>&1 || true
        done
    ) &
fi

# --- 13.7. Pre-warm QMD embeddings (background) ---
# Generates embeddings so the first memory_search isn't slow.
# GGUF models + compiled binaries persist in /data/.cache via the ~/.cache symlink.
# Delayed to let the gateway create collections first.
echo "Scheduling QMD embedding warm-up..."
(
    sleep 30
    su - agent -c 'source /data/.env.secrets && qmd embed' \
        >>/data/logs/qmd-warmup.log 2>&1 || true
) &

# --- 14. Start gateway (foreground, PID 1) ---
# OPENAI_API_KEY is kept in the gateway env for TTS/STT and OpenAI-dependent
# services. The Codex wrapper (/usr/local/bin/codex) unsets it per-invocation
# so Codex uses OAuth subscription auth instead.
# Clean stale gateway lock files (may persist if the machine was killed mid-run)
rm -f -- "$STATE_DIR"/gateway.*.lock

echo "=== Clawd Ready ==="
exec su - agent -c 'source /data/.env.secrets && openclaw gateway run --port 18789 2>&1 | tee /data/logs/gateway.log'
