#!/usr/bin/env bash
set -euo pipefail

SANDBOX_NAME="${1:-clawd}"

echo "Applying network policy to sandbox '$SANDBOX_NAME'..."
echo "  Policy: deny-by-default with allowlist"

docker sandbox network proxy "$SANDBOX_NAME" \
    --policy deny \
    --allow-host "api.anthropic.com" \
    --allow-host "api.telegram.org" \
    --allow-host "registry.npmjs.org" \
    --allow-host "*.npmjs.org" \
    --allow-host "github.com" \
    --allow-host "api.github.com" \
    --allow-host "*.githubusercontent.com"

echo "Network policy applied."
echo "  Allowed: api.anthropic.com, api.telegram.org, *.npmjs.org, github.com"
