# Clawd

Personal AI assistant powered by [OpenClaw](https://openclaw.ai). Runs locally in a
[Docker AI Sandbox](https://docs.docker.com/ai/sandboxes/) or remotely on
[Fly.io](https://fly.io) with optional [Tailscale](https://tailscale.com) SSH.

## Prerequisites

- [OpenRouter API key](https://openrouter.ai/) (recommended) or
  [Anthropic API key](https://console.anthropic.com/)
- [Telegram bot token](https://t.me/BotFather) (create via `/newbot`) — must be a **dedicated**
  token not used by any other running bot

**Local only:** [Docker Desktop](https://www.docker.com/products/docker-desktop/) 4.58+ (AI
Sandbox support)

**Remote only:** [flyctl](https://fly.io/docs/flyctl/install/)

## Quick Start (Local)

```bash
# 1. Configure secrets
cp .env.example .env
# Edit .env — set OPENROUTER_API_KEY (or ANTHROPIC_API_KEY) and TELEGRAM_BOT_TOKEN
# Set TELEGRAM_ALLOWED_IDS to your Telegram user ID (find it via @userinfobot)

# 2. Build template + create sandbox + start gateway
make up

# 3. DM your bot on Telegram
```

## Remote Deployment (Fly.io)

```bash
# 1. Generate fly.toml
make fly-init APP=my-clawd

# 2. Create the app + set secrets
fly apps create my-clawd
fly secrets set \
    OPENROUTER_API_KEY='sk-or-...' \
    TELEGRAM_BOT_TOKEN='123456:ABC-DEF...' \
    OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 16)" \
    TELEGRAM_ALLOWED_IDS='12345678' \
    -a my-clawd

# 3. Deploy
make deploy
```

After editing config or workspace files, redeploy with `make deploy`.

### Tailscale SSH (Optional)

```bash
fly secrets set TAILSCALE_AUTHKEY='tskey-auth-...' -a my-clawd
make deploy

# SSH in (Tailscale handles auth, no keys needed)
ssh agent@my-clawd
```

### Git, SSH & GitHub Setup

Requires Tailscale SSH. Run once — state persists on the `/data` volume across redeploys.

```bash
ssh -t agent@my-clawd vm-setup.sh
```

The wizard configures git identity, SSH key generation, commit signing, and GitHub CLI auth. After
it completes, add the printed public key to
[github.com/settings/keys](https://github.com/settings/keys) as both an **Authentication** and
**Signing** key.

**GitHub CLI (`gh`):** To enable `gh pr create`, `gh issue list`, etc. on the VM, set a
[personal access token](https://github.com/settings/tokens) (classic, `repo` scope) as a Fly
secret:

```bash
fly secrets set GH_TOKEN='ghp_...' -a my-clawd
make deploy
```

The token is picked up automatically — no interactive `gh auth login` needed.

### State Backup & Restore (Optional)

Protect agent state (memory, workspace files, config) against volume loss with a private Git repo.

1. Create a private repo (e.g., `your-user/agent-state`)
2. Add the SSH key from `vm-setup.sh` as a deploy key with **write access**
3. Set the Fly secret:

```bash
fly secrets set STATE_REPO='git@github.com:your-user/agent-state.git' -a my-clawd
make deploy
```

**How it works:**

- A background sync loop pushes state to the repo every 30 minutes (no API credits — pure shell)
- On fresh volume deployments, the entrypoint detects no existing state and restores from the repo
- Existing volumes are never affected — restore only triggers when `MEMORY.md` is absent
- Set `STATE_SYNC_INTERVAL` (seconds) to change the sync frequency (default: `1800`)

**Repo structure:**

```
agent-state/
├── openclaw.json
├── workspace/
│   ├── MEMORY.md
│   ├── memory/
│   ├── AGENTS.md
│   ├── SOUL.md
│   └── ...
├── cron/
│   └── jobs.json
└── agents/
```

**Logs:** SSH in and check `/data/logs/state-sync.log`.

## Configuration

### Model

Set in `config/openclaw.json` at `agents.defaults.model.primary`. For OpenRouter, prefix with
`openrouter/` (e.g. `openrouter/anthropic/claude-sonnet-4.5`). For direct Anthropic, use bare
model IDs (e.g. `anthropic/claude-sonnet-4-20250514`). Run `make reset` (local) or `make deploy`
(remote) to apply.

List available models: `make shell` then `openclaw models list --all --provider openrouter`.

### TTS

Voice message support via OpenAI's TTS API. Configured in `config/openclaw.json` under
`messages.tts`:

```json
"messages": {
  "tts": {
    "auto": "off",
    "provider": "openai"
  }
}
```

`auto` accepts `off`, `always`, `inbound` (only for audio messages), or `tagged`. Can be changed
per-session in Telegram with `/tts always`, `/tts off`, etc. Requires `OPENAI_API_KEY`.

### Telegram Access Control

Uses `dmPolicy: "allowlist"` — only user IDs in `TELEGRAM_ALLOWED_IDS` can message the bot. IDs
are injected into the config at startup.

## Commands

| Command                    | Description                            |
| -------------------------- | -------------------------------------- |
| `make up`                  | Build + create sandbox + start gateway |
| `make down`                | Stop sandbox                           |
| `make shell`               | Interactive shell in sandbox           |
| `make logs`                | Tail gateway logs                      |
| `make status`              | Check sandbox and gateway health       |
| `make reset`               | Destroy and recreate sandbox           |
| `make setup`               | Install pre-commit hooks               |
| `make format`              | Auto-format with Prettier              |
| `make format-check`        | Check formatting (CI)                  |
| `make lint`                | Run all linters                        |
| `make lint-shell`          | Lint shell scripts (shellcheck)        |
| `make lint-docker`         | Lint Dockerfiles (hadolint)            |
| **Remote (Fly.io)**        |                                        |
| `make fly-init APP=<name>` | Generate `fly.toml` from template      |
| `make deploy`              | Deploy to Fly.io                       |
| `make fly-logs`            | Tail remote logs                       |
| `make fly-status`          | Check remote VM status                 |
| `make fly-console`         | SSH into remote VM                     |

## Repo Structure

```
clawd/
├── Makefile
├── .env.example
├── config/
│   ├── openclaw.json
│   └── workspace/          # Bot personality + skills
├── template/
│   └── Dockerfile          # Local sandbox image
├── scripts/                # Sandbox lifecycle
├── remote/
│   ├── Dockerfile          # Fly.io image
│   ├── entrypoint.sh
│   ├── state-sync.sh       # Periodic state → git repo sync
│   ├── vm-setup.sh
│   ├── fly.toml.example
│   ├── fly-init.sh
│   └── deploy.sh
└── package.json            # Prettier
```

## Troubleshooting

**409 Conflict: terminated by other getUpdates request** — another process is polling with the same
bot token. Use a dedicated token, or clear stale state:

```bash
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true"
make reset
```

**Bot doesn't respond** — verify your Telegram user ID is in `TELEGRAM_ALLOWED_IDS`. Find it via
[@userinfobot](https://t.me/userinfobot). After updating `.env`, run `make reset`.

## Links

- [OpenClaw docs](https://docs.openclaw.ai)
- [Gateway configuration](https://docs.openclaw.ai/gateway/configuration)
- [Telegram channel](https://docs.openclaw.ai/channels/telegram)
- [Skills](https://docs.openclaw.ai/tools/skills)
- [Docker AI Sandboxes](https://docs.docker.com/ai/sandboxes/)
