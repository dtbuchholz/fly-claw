#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Resolve app name from fly.toml (same logic as Makefile)
FLY_APP="${1:-}"
if [ -z "$FLY_APP" ] && [ -f "$ROOT_DIR/fly.toml" ]; then
    FLY_APP=$(sed -n 's/^app *= *"\(.*\)"/\1/p' "$ROOT_DIR/fly.toml" | head -1)
fi
if [ -z "$FLY_APP" ]; then
    echo "Usage: $0 [app-name]"
    echo "  Or generate fly.toml first: make fly-init APP=<name>"
    exit 1
fi

echo "=== Gateway OAuth Setup ==="
echo "App: $FLY_APP"
echo ""
echo "This sets up gateway + ACP auth for Codex, plus optional Claude CLI fallback."
echo "Credentials persist on the /data volume across redeploys."
echo ""

cat <<'EOF'
Opening interactive SSH session as the agent user.
Run these commands:
──────────────────────────────────────────────────────

  # 1. Codex (OpenAI) — device auth flow
  #    Prints a URL + code. Open URL in browser, enter the code.
  #    Credentials are stored in ~/.codex/auth.json automatically.
  codex login --device-auth

  # 2. Import that Codex OAuth login into OpenClaw.
  #    This is the supported interactive path for current upstream builds.
  openclaw onboard --auth-choice openai-codex

  # 3. Optional: register Claude CLI as a fallback provider.
  claude auth login
  openclaw onboard --auth-choice anthropic-cli

  # 4. Verify
  codex login status
  jq '.profiles | keys' ~/.openclaw/agents/main/agent/auth-profiles.json
  jq '{currentModel, defaultModel, providers: (.providers | keys?)}' ~/.openclaw/agents/main/agent/models.json

  exit

──────────────────────────────────────────────────────

EOF

fly ssh console -a "$FLY_APP" -u agent

echo ""
echo "=== Done ==="
echo ""
echo "Codex OAuth is stored on /data/.codex/auth.json, not as a Fly secret."
echo "If you also want Anthropic or OpenRouter fallback,"
echo "set those provider secrets separately with fly secrets set."
