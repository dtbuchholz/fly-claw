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

echo "=== ACP OAuth Setup ==="
echo "App: $FLY_APP"
echo ""
echo "This sets up OAuth for Claude Code + Codex ACP harnesses."
echo "Tokens persist on the /data volume across redeploys."
echo ""

cat <<'EOF'
Opening interactive SSH session. Run these commands:
──────────────────────────────────────────────────────

  su - agent

  # 1. Claude Code (Anthropic) — setup-token flow
  #    Prints a URL → open in browser → copy the token.
  #    Then set it as a Fly secret (NOT stored in the CLI):
  #
  #      claude setup-token
  #      exit  # back to root
  #      exit  # back to local
  #      fly secrets set CLAUDE_CODE_OAUTH_TOKEN="sk-ant-oat01-..." -a <app>
  #
  claude setup-token

  # 2. Codex (OpenAI) — device auth flow
  #    Prints a URL + code. Open URL in browser, enter the code.
  #    Credentials are stored in ~/.codex/auth.json automatically.
  codex login --device-auth

  # 3. Verify
  claude auth status
  codex login status

  exit  # exit agent shell
  exit  # exit SSH

──────────────────────────────────────────────────────

NOTE: After exiting, set the Claude token as a Fly secret:

  fly secrets set CLAUDE_CODE_OAUTH_TOKEN="<token>" -a <app>

EOF

fly ssh console -a "$FLY_APP"

echo ""
echo "=== Done ==="
echo ""
echo "Don't forget to set the Claude Code token as a Fly secret:"
echo "  fly secrets set CLAUDE_CODE_OAUTH_TOKEN=\"<token>\" -a $FLY_APP"
