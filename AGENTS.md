# AGENTS.md

Configuration for AI assistants working on this codebase.

## Project Overview

**Clawd** — infrastructure for running [OpenClaw](https://openclaw.ai) (a personal AI assistant) inside [Docker AI Sandboxes](https://docs.docker.com/ai/sandboxes/). This repo contains the sandbox template, OpenClaw configuration, lifecycle scripts, and Makefile orchestration. It does not contain OpenClaw itself (that's installed via npm at build time).

## Repo Structure

```
clawd/
├── template/
│   └── Dockerfile                # Sandbox template extending docker/sandbox-templates:claude-code
│                                 # Upgrades Node to 22.x, installs OpenClaw globally
├── config/
│   ├── openclaw.json             # OpenClaw gateway config (no secrets, committed)
│   └── workspace/
│       ├── AGENTS.md             # Bot personality (injected into OpenClaw at runtime)
│       └── SOUL.md               # Bot identity
├── scripts/
│   ├── sandbox-up.sh             # Create sandbox, copy config, apply network policy, start gateway
│   ├── sandbox-down.sh           # Stop sandbox
│   ├── sandbox-status.sh         # Health check (sandbox + gateway)
│   ├── sandbox-logs.sh           # Tail gateway logs
│   └── network-policy.sh         # Deny-by-default network proxy rules
├── Makefile                      # Primary interface for all operations
├── .env.example                  # Template for secrets (ANTHROPIC_API_KEY, TELEGRAM_BOT_TOKEN)
└── remote/                       # Phase 3: Fly.io + Tailscale deployment (future)
```

## Quick Commands

```bash
make build          # Build custom sandbox template image
make up             # Build + create sandbox + start OpenClaw gateway
make down           # Stop sandbox
make shell          # Interactive shell inside sandbox
make logs           # Tail OpenClaw gateway logs
make status         # Check sandbox and gateway health
make reset          # Destroy and recreate from scratch
make onboard        # Run OpenClaw onboarding wizard
make network-setup  # Apply network proxy rules
```

## Code Style

### Shell Scripts

- Shebang: `#!/usr/bin/env bash`
- Error handling: `set -euo pipefail` at top
- Always quote variables: `"$VAR"` not `$VAR`
- Scripts in `scripts/` should be idempotent where possible
- Lint with `shellcheck`

### Dockerfile

- Extends `docker/sandbox-templates:claude-code` (the Docker AI Sandbox base image)
- Base image ships Node 20.x — must upgrade to 22.x before installing OpenClaw (`>=22.12.0` required)
- Switch to `root` for installs, back to `agent` user before end
- Use `rm -rf /var/lib/apt/lists/*` after apt-get

### Configuration

- `config/openclaw.json` is committed — **never put secrets here**
- Secrets live in `.env` (gitignored) and flow via environment variables
- OpenClaw reads `ANTHROPIC_API_KEY` and `TELEGRAM_BOT_TOKEN` from env natively

## Secrets Flow

```
.env (host, gitignored)
  → shell environment (source .env)
    → docker sandbox exec -e KEY=VALUE
      → OpenClaw gateway process (reads from env)
```

Secrets are never written to files inside the sandbox.

## Architecture Notes

- **Docker sandbox = microVM**, not a container. Uses `virtualization.framework` on macOS. Sandboxes don't show in `docker ps`. Managed via `docker sandbox` CLI.
- **`config/workspace/AGENTS.md`** is the OpenClaw bot personality file — completely different from this file. It gets copied into `~/.openclaw/workspace/` inside the sandbox and is injected into the assistant's system prompt.
- **`sandbox.mode: "off"`** in `config/openclaw.json` disables OpenClaw's own Docker sandboxing for tool execution. This is correct because the entire gateway already runs inside a sandbox — nesting would be redundant and likely broken.
- **Network policy** is deny-by-default. Only `api.anthropic.com`, `api.telegram.org`, `*.npmjs.org`, `github.com` are allowed. Configured in `scripts/network-policy.sh`.

## Verification

```bash
make build    # Template image builds successfully
make up       # Sandbox created, config copied, gateway starts
make status   # Reports healthy gateway
make logs     # Shows gateway startup and Telegram connection
make down     # Stops cleanly
```
