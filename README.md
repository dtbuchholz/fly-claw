# Clawd

Personal AI assistant powered by [OpenClaw](https://openclaw.ai). Runs locally in a
[Docker AI Sandbox](https://docs.docker.com/ai/sandboxes/) or remotely on
[Fly.io](https://fly.io) with optional [Tailscale](https://tailscale.com) SSH.

## Prerequisites

- ChatGPT/Codex subscription login for the recommended `openai-codex` path, or a
  direct fallback provider key such as an
  [Anthropic API key](https://console.anthropic.com/) or
  [OpenRouter API key](https://openrouter.ai/)
- Optional [OpenAI API key](https://platform.openai.com/) for voice features only
- [Telegram bot token](https://t.me/BotFather) (create via `/newbot`) — must be a **dedicated**
  token not used by any other running bot

**Local only:** [Docker Desktop](https://www.docker.com/products/docker-desktop/) 4.58+ (AI
Sandbox support)

**Remote only:** [flyctl](https://fly.io/docs/flyctl/install/)

## Quick Start (Local)

```bash
# 1. Configure secrets
cp .env.example .env
# Edit .env — set ANTHROPIC_API_KEY or OPENROUTER_API_KEY, plus TELEGRAM_BOT_TOKEN
# Optional: set OPENAI_API_KEY only if you want TTS/STT voice features
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
    TELEGRAM_BOT_TOKEN='123456:ABC-DEF...' \
    OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 16)" \
    TELEGRAM_ALLOWED_IDS='12345678' \
    -a my-clawd
# Optional: add ANTHROPIC_API_KEY / OPENROUTER_API_KEY for model fallbacks
# Optional: add OPENAI_API_KEY for voice features only

# 3. Deploy
make deploy

# 4. Set up Codex OAuth on the VM (recommended primary path)
make fly-auth
```

After editing config or workspace files, redeploy with `make deploy`.

To force-refresh agent config and upsert repo-managed cron jobs (by job id) while preserving custom live jobs, use:

```bash
make deploy-force-cron-upsert
```

To upsert only repo-managed cron jobs (without forcing all agent config defaults), use:

```bash
make deploy-cron-upsert
```

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
fly secrets set GITHUB_TOKEN='ghp_...' -a my-clawd
make deploy
```

The token is picked up automatically (`GITHUB_TOKEN`; legacy `GH_TOKEN` also works) — no interactive `gh auth login` needed.

### Slack (Optional)

Enable the Slack channel by setting tokens from your
[Slack app](https://api.slack.com/apps) (Socket Mode must be enabled):

```bash
fly secrets set \
    SLACK_APP_TOKEN='xapp-...' \
    SLACK_BOT_TOKEN='xoxb-...' \
    -a my-clawd
make deploy
```

The bot responds in any channel it's invited to (`groupPolicy: "open"`).

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

Set in `config/openclaw.json` at `agents.defaults.model.primary`. The repo now defaults to
`openai-codex/gpt-5.4`, which uses ChatGPT/Codex OAuth through OpenClaw's native `openai-codex`
provider. Anthropic API models use `anthropic/`, Claude CLI models use `claude-cli/`, and
OpenRouter models use `openrouter/`. This repo does not use `OPENAI_API_KEY` for model routing.
Run `make reset`
(local) or `make deploy` (remote) to apply.

List available models: `make shell` then `openclaw models list --all`.

### Cron Model Overrides

Repo-managed cron jobs use the normal cron model by default, and the `working-context-snapshot`
job can use a separate lightweight model when configured.

- `CRON_MODEL` overrides the standard cron model for all repo-managed cron jobs
- `CRON_LIGHT_MODEL` overrides only the lightweight cron lane, currently the
  `working-context-snapshot` job

Example:

```bash
fly secrets set \
  CRON_MODEL='openai-codex/gpt-5.4' \
  CRON_LIGHT_MODEL='openai-codex/gpt-5.3-codex-spark' \
  -a my-clawd
make deploy-cron-upsert
```

`CRON_LIGHT_MODEL` is optional. If unset, the lightweight lane falls back to `CRON_MODEL`.
This is intentional because Codex Spark is entitlement-dependent.

### Codex OAuth Setup

On current OpenClaw builds, the reliable manual import path is:

```bash
codex login --device-auth
openclaw onboard --auth-choice openai-codex
```

This reuses `~/.codex/auth.json` and writes the OpenClaw-side auth profile. The repo does not try
to run this automatically at boot because upstream now requires an interactive TTY for provider
registration/import flows.

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

### Telegram Groups (Optional)

The bot can participate in Telegram group chats with topics enabled:

1. Create a group and enable **Topics** (Group settings → Topics → Enable)
2. Add the bot to the group and **make it an admin**
3. Disable privacy mode via BotFather (`/setprivacy` → Disable)
4. Send a message in the group, then check `make fly-logs` for the group chat ID
5. Set the group ID as a Fly secret:

```bash
fly secrets set TELEGRAM_GROUP_IDS='-1003782901451' -a my-clawd
make deploy
```

Multiple groups can be comma-separated. The bot will respond without requiring `@mentions` in
allowed groups.

## Commands

| Command                         | Description                                                   |
| ------------------------------- | ------------------------------------------------------------- |
| `make up`                       | Build + create sandbox + start gateway                        |
| `make down`                     | Stop sandbox                                                  |
| `make shell`                    | Interactive shell in sandbox                                  |
| `make logs`                     | Tail gateway logs                                             |
| `make status`                   | Check sandbox and gateway health                              |
| `make reset`                    | Destroy and recreate sandbox                                  |
| `make setup`                    | Install pre-commit hooks                                      |
| `make format`                   | Auto-format with Prettier                                     |
| `make format-check`             | Check formatting (CI)                                         |
| `make lint`                     | Run all linters                                               |
| `make lint-shell`               | Lint shell scripts (shellcheck)                               |
| `make lint-docker`              | Lint Dockerfiles (hadolint)                                   |
| **Remote (Fly.io)**             |                                                               |
| `make fly-init APP=<name>`      | Generate `fly.toml` from template                             |
| `make deploy`                   | Deploy to Fly.io                                              |
| `make deploy-force`             | Deploy + overwrite agent config                               |
| `make deploy-cron-upsert`       | Deploy + upsert repo cron jobs by id (preserve custom jobs)   |
| `make deploy-force-cron-upsert` | Deploy + overwrite agent config + upsert repo cron jobs by id |
| `make fly-logs`                 | Tail remote logs                                              |
| `make fly-status`               | Check remote VM status                                        |
| `make fly-console`              | SSH into remote VM                                            |
| `make fly-auth`                 | Run interactive gateway + ACP OAuth setup (Codex primary)     |
| `make fly-codex-auth-reset`     | Remove Codex API-key auth profile on VM (forces OAuth login)  |

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
