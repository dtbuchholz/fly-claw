#!/usr/bin/env bash
set -euo pipefail

SANDBOX_NAME="${1:-clawd}"

docker sandbox exec "$SANDBOX_NAME" tail -f /tmp/openclaw-gateway.log
