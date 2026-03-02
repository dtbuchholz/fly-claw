#!/usr/bin/env bash
# Agent-facing wrapper for state sync (called by OpenClaw cron job).
# Sources secrets and delegates to the system-level script.
set -euo pipefail

[ -f /data/.env.secrets ] && source /data/.env.secrets

exec /usr/local/bin/state-sync.sh
# Exit codes: 0 = synced or no changes, 1 = push failed
