#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

APP_NAME="${1:-}"
if [ -z "$APP_NAME" ] && [ -f "$ROOT_DIR/fly.toml" ]; then
    APP_NAME=$(sed -n 's/^app *= *"\(.*\)"/\1/p' "$ROOT_DIR/fly.toml" | head -1)
fi
if [ -z "$APP_NAME" ]; then
    echo "Usage: $0 [app-name]"
    echo "  Or generate fly.toml first: make fly-init APP=<name>"
    exit 1
fi

echo "Resetting Codex API-key auth mode on app: $APP_NAME"

# shellcheck disable=SC2016
fly ssh console -a "$APP_NAME" -C 'sh -lc '"'"'
set -e
AUTH_FILE="/data/.codex/auth.json"
if [ -f "$AUTH_FILE" ]; then
  mode=$(jq -r ".auth_mode // .authMode // empty" "$AUTH_FILE" 2>/dev/null || true)
  if [ "$mode" = "apikey" ]; then
    backup="/data/.codex/auth.apikey.$(date -u +%Y%m%dT%H%M%SZ).json"
    cp "$AUTH_FILE" "$backup"
    chmod 600 "$backup"
    chown agent:agent "$backup" || true
    rm -f "$AUTH_FILE"
    echo "Removed Codex apikey auth profile."
    echo "Backup: $backup"
  else
    echo "Codex auth mode is ${mode:-unknown}; no reset needed."
  fi
else
  echo "Codex auth file not found; no reset needed."
fi

echo
echo "Current Codex login status:"
su - agent -c "codex login status" || true
'"'"''

echo
echo "Next step: run 'make fly-auth' and complete 'codex login --device-auth'."
