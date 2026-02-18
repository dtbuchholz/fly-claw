#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# --- Prereqs ---
if ! command -v fly &>/dev/null; then
    echo "Error: flyctl not installed. https://fly.io/docs/flyctl/install/"
    exit 1
fi

if ! fly auth whoami &>/dev/null; then
    echo "Error: not logged in. Run: fly auth login"
    exit 1
fi

if [ ! -f "$ROOT_DIR/fly.toml" ]; then
    echo "Error: fly.toml not found. Run: make fly-init APP=<app-name>"
    exit 1
fi

# Parse app name from fly.toml
APP_NAME=$(grep '^app' "$ROOT_DIR/fly.toml" | head -1 | sed 's/app *= *"\(.*\)"/\1/')

if [ -z "$APP_NAME" ]; then
    echo "Error: could not parse app name from fly.toml"
    exit 1
fi

echo "Deploying to: $APP_NAME"

# --- Create app if it doesn't exist ---
if ! fly apps list --json 2>/dev/null | jq -e ".[] | select(.Name == \"$APP_NAME\")" &>/dev/null; then
    echo "Creating app '$APP_NAME'..."
    fly apps create "$APP_NAME"
fi

# --- Create volume if it doesn't exist ---
if ! fly volumes list -a "$APP_NAME" --json 2>/dev/null | jq -e '.[0]' &>/dev/null; then
    REGION=$(grep '^primary_region' "$ROOT_DIR/fly.toml" | sed 's/primary_region *= *"\(.*\)"/\1/')
    echo "Creating volume 'clawd_data' in $REGION..."
    fly volumes create clawd_data --region "$REGION" --size 3 -a "$APP_NAME" -y
fi

# --- Validate secrets ---
# fly secrets list may fail for apps with no machines (pre-first-deploy);
# in that case skip validation — staged secrets exist but aren't queryable
SECRETS_JSON=$(fly secrets list -a "$APP_NAME" --json 2>/dev/null) || {
    echo "Note: cannot query secrets (first deploy?). Skipping validation."
    SECRETS_JSON=""
}

if [ -n "$SECRETS_JSON" ]; then
    has_secret() { echo "$SECRETS_JSON" | jq -e ".[] | select(.name == \"$1\")" &>/dev/null; }

    MISSING=()
    has_secret "OPENCLAW_GATEWAY_TOKEN" || MISSING+=("OPENCLAW_GATEWAY_TOKEN")
    has_secret "TELEGRAM_BOT_TOKEN"     || MISSING+=("TELEGRAM_BOT_TOKEN")

    if ! has_secret "OPENROUTER_API_KEY" && ! has_secret "ANTHROPIC_API_KEY"; then
        MISSING+=("OPENROUTER_API_KEY or ANTHROPIC_API_KEY")
    fi

    if [ ${#MISSING[@]} -gt 0 ]; then
        echo ""
        echo "Error: missing required secrets:"
        for s in "${MISSING[@]}"; do
            echo "  - $s"
        done
        echo ""
        echo "Set them with: fly secrets set KEY=value -a $APP_NAME"
        exit 1
    fi

    # Warn about optional
    has_secret "TAILSCALE_AUTHKEY"    || echo "Note: TAILSCALE_AUTHKEY not set (Tailscale SSH disabled)"
    has_secret "TELEGRAM_ALLOWED_IDS" || echo "Warning: TELEGRAM_ALLOWED_IDS not set (bot accepts DMs from anyone)"
    has_secret "GH_TOKEN"             || echo "Note: GH_TOKEN not set (gh CLI won't work)"
    has_secret "STATE_REPO"            || echo "Note: STATE_REPO not set (state sync disabled)"
fi

# --- Deploy ---
echo ""
fly deploy -a "$APP_NAME" --config "$ROOT_DIR/fly.toml"
