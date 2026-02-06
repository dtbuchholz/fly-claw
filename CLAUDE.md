# Clawd

Personal AI assistant (OpenClaw) running in a Docker AI Sandbox.

## Architecture

- `template/Dockerfile` - Custom sandbox template extending `docker/sandbox-templates:claude-code`
- `config/openclaw.json` - OpenClaw gateway config (no secrets)
- `config/workspace/` - Agent personality files (AGENTS.md, SOUL.md) and skills
- `scripts/` - Sandbox lifecycle scripts
- `Makefile` - Primary interface (`make up`, `make down`, `make shell`, etc.)

## Workflow Guidelines

1. **Read AGENTS.md** for code style and project structure
2. Run `make build` to verify the template builds after changes
3. Never put secrets in committed files — use `.env`

## Secrets

Secrets live in `.env` (gitignored). They are passed to the sandbox via environment variables, never written to files inside the sandbox. The startup script (`sandbox-up.sh`) also registers API keys in the agent auth store via `openclaw onboard`.

## API Provider

Supports OpenRouter (recommended) or direct Anthropic. Set one in `.env`:

- **OpenRouter**: `OPENROUTER_API_KEY=sk-or-...` — model IDs in config use `openrouter/` prefix (e.g. `openrouter/anthropic/claude-opus-4.5`)
- **Anthropic**: `ANTHROPIC_API_KEY=sk-ant-...` — model IDs use bare names (e.g. `claude-sonnet-4-20250514`)

The model is configured in `config/openclaw.json` at `agents.defaults.model.primary`.

## Telegram Access Control

Uses `dmPolicy: "allowlist"`. Set `TELEGRAM_ALLOWED_IDS` in `.env` (comma-separated numeric IDs). The startup script injects these into the config via `jq`.

## Key Commands

```bash
make up       # Build template + create sandbox + start gateway
make shell    # Interactive shell in sandbox
make logs     # Tail gateway logs
make down     # Stop sandbox
make reset    # Destroy and recreate
```

## OpenClaw Docs

- Gateway config: https://docs.openclaw.ai/gateway/configuration
- Telegram channel: https://docs.openclaw.ai/channels/telegram
- Skills: https://docs.openclaw.ai/tools/skills
