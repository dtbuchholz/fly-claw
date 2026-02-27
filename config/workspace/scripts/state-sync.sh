#!/usr/bin/env bash
# Agent-facing wrapper for state sync.
# Sources secrets and delegates to the system-level script.
set -euo pipefail

[ -f /data/.env.secrets ] && source /data/.env.secrets

exec /usr/local/bin/state-sync.sh
