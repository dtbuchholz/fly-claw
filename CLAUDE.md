# Clawd

Personal AI assistant (OpenClaw) running in a Docker AI Sandbox (local) or Fly.io VM (remote).

## Architecture

### Local (Docker Sandbox)

- `template/Dockerfile` - Custom sandbox template extending `docker/sandbox-templates:claude-code`
- `config/openclaw.json` - OpenClaw gateway config (no secrets)
- `config/workspace/` - Agent personality files (AGENTS.md, SOUL.md) and skills
- `scripts/` - Sandbox lifecycle scripts
- `Makefile` - Primary interface (`make up`, `make down`, `make shell`, etc.)

### Remote (Fly.io)

- `remote/Dockerfile` - Standalone image (debian:bookworm-slim + Node 22 + Chromium + Tailscale + OpenClaw)
- `remote/entrypoint.sh` - VM init: secrets, config injection, optional Tailscale, state sync, gateway startup
- `remote/state-sync.sh` - Periodic sync of live state (`/data/.openclaw`) to a remote git repo
- `remote/fly.toml.example` - Fly.io config template with `{{APP_NAME}}`/`{{REGION}}` placeholders
- `remote/fly-init.sh` - Generates `fly.toml` from template
- `remote/deploy.sh` - Validates secrets, creates app/volume if needed, runs `fly deploy`
- `remote/vm-setup.sh` - Interactive wizard for git identity, SSH keys, commit signing, GitHub CLI

## Workflow Guidelines

1. **Read AGENTS.md** for code style and project structure
2. Run `make build` to verify the template builds after changes
3. Run `make lint` to check formatting + shell scripts + Dockerfiles
4. Never put secrets in committed files — use `.env`
5. Run `make setup` once after cloning to install pre-commit hooks

## Secrets

Secrets live in `.env` (gitignored). They are passed to the sandbox via environment variables, never written to files inside the sandbox. The startup script (`sandbox-up.sh`) also registers API keys in the agent auth store via `openclaw onboard`.

## API Provider

Supports OpenRouter (recommended) or direct Anthropic. Set one in `.env`:

- **OpenRouter**: `OPENROUTER_API_KEY=sk-or-...` — model IDs in config use `openrouter/` prefix (e.g. `openrouter/anthropic/claude-opus-4.5`)
- **Anthropic**: `ANTHROPIC_API_KEY=sk-ant-...` — model IDs use bare names (e.g. `claude-sonnet-4-20250514`)

The model is configured in `config/openclaw.json` at `agents.defaults.model.primary`.

## Telegram Access Control

Uses `dmPolicy: "allowlist"`. Set `TELEGRAM_ALLOWED_IDS` in `.env` (comma-separated numeric IDs). The startup script injects these into the config via `jq`.

## State Sync

If `STATE_REPO` is set (as a Fly secret), the remote VM automatically syncs live state to a git repo for disaster recovery.

**How it works:**

- On fresh volumes (no `MEMORY.md` found), entrypoint restores state from the repo — workspace, config, cron jobs, and agent data
- A background loop runs `state-sync.sh` every 30 minutes, pushing changes back to the repo
- The persistent clone lives at `/data/state-repo` (shared between restore and sync)
- Only commits when changes are detected; commit messages include a UTC timestamp

**Env vars (Fly secrets):**

- `STATE_REPO` — SSH URL of the state git repo (e.g. `git@github.com:user/clawd-state.git`). Required to enable sync.
- `STATE_SYNC_INTERVAL` — Seconds between syncs (default: `1800` / 30 minutes)

**Prerequisites:** SSH key and git identity must be configured on the VM via `vm-setup.sh` for push access.

**Synced paths:** `workspace/`, `openclaw.json`, `cron/`, `agents/` (the repo's `.gitignore` excludes sensitive dirs like `identity/` and `credentials/`).

**Logs:** `/data/logs/state-sync.log`

## Key Commands

```bash
# Local (Docker Sandbox)
make up       # Build template + create sandbox + start gateway
make shell    # Interactive shell in sandbox
make logs     # Tail gateway logs
make down     # Stop sandbox
make reset    # Destroy and recreate

# Remote (Fly.io)
make fly-init APP=<name>  # Generate fly.toml from template
make deploy               # Deploy to Fly.io
make fly-logs             # Tail remote logs
make fly-status           # Check remote VM status
make fly-console          # SSH into remote VM
```

## OpenClaw Docs

- Gateway config: https://docs.openclaw.ai/gateway/configuration
- Telegram channel: https://docs.openclaw.ai/channels/telegram
- Skills: https://docs.openclaw.ai/tools/skills
