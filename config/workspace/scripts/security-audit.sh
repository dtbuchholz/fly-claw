#!/usr/bin/env bash
# Security audit for Clawd deployment.
# Exits 0 if clean, 1 if issues found. Output only on issues.
set -uo pipefail

issues=()

# --- Gateway bind address (should be loopback) ---
if [ -f /data/.openclaw/openclaw.json ]; then
    bind=$(jq -r '.gateway.bind // "unknown"' /data/.openclaw/openclaw.json)
    if [ "$bind" != "loopback" ] && [ "$bind" != "127.0.0.1" ]; then
        issues+=("WARN: Gateway bind is '$bind' — expected 'loopback'")
    fi
else
    issues+=("CRIT: Config file /data/.openclaw/openclaw.json not found")
fi

# --- Auth mode (should be token) ---
if [ -f /data/.openclaw/openclaw.json ]; then
    auth=$(jq -r '.gateway.auth.mode // "unknown"' /data/.openclaw/openclaw.json)
    if [ "$auth" != "token" ]; then
        issues+=("WARN: Auth mode is '$auth' — expected 'token'")
    fi
fi

# --- Config file permissions (should be 600) ---
if [ -f /data/.openclaw/openclaw.json ]; then
    perms=$(stat -c '%a' /data/.openclaw/openclaw.json 2>/dev/null || stat -f '%Lp' /data/.openclaw/openclaw.json 2>/dev/null)
    if [ "$perms" != "600" ]; then
        issues+=("WARN: Config perms are $perms — expected 600")
    fi
fi

# --- .openclaw dir permissions (should be 700) ---
if [ -d /data/.openclaw ]; then
    perms=$(stat -c '%a' /data/.openclaw 2>/dev/null || stat -f '%Lp' /data/.openclaw 2>/dev/null)
    if [ "$perms" != "700" ]; then
        issues+=("WARN: .openclaw dir perms are $perms — expected 700")
    fi
fi

# --- Secrets file permissions (should be 600) ---
if [ -f /data/.env.secrets ]; then
    perms=$(stat -c '%a' /data/.env.secrets 2>/dev/null || stat -f '%Lp' /data/.env.secrets 2>/dev/null)
    if [ "$perms" != "600" ]; then
        issues+=("WARN: .env.secrets perms are $perms — expected 600")
    fi
else
    issues+=("WARN: /data/.env.secrets not found")
fi

# --- Tailscale status (if installed) ---
if command -v tailscale &>/dev/null; then
    if ! tailscale status &>/dev/null; then
        issues+=("INFO: Tailscale installed but not connected")
    fi
fi

# --- Disk usage (warn above 85%) ---
disk_pct=$(df /data 2>/dev/null | awk 'NR==2 {gsub(/%/,""); print $5}')
if [ -n "$disk_pct" ] && [ "$disk_pct" -gt 85 ] 2>/dev/null; then
    issues+=("WARN: Disk usage at ${disk_pct}% on /data")
fi

# --- Unexpected listening ports ---
# Expected: 18789 (gateway), 18800 (chromium CDP)
if command -v ss &>/dev/null; then
    unexpected=$(ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' \
        | grep -v -E ':(18789|18800)$' \
        | grep -v '127.0.0.1' \
        | grep -v '\[::1\]' || true)
    if [ -n "$unexpected" ]; then
        issues+=("INFO: Unexpected listening ports: $unexpected")
    fi
fi

# --- Report ---
if [ ${#issues[@]} -gt 0 ]; then
    echo "Security audit found ${#issues[@]} issue(s):"
    for issue in "${issues[@]}"; do
        echo "  - $issue"
    done
    exit 1
fi

exit 0
