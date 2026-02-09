# Clawd

Personal AI assistant ([OpenClaw](https://openclaw.ai)) running in a
[Docker AI Sandbox](https://docs.docker.com/ai/sandboxes/) for hypervisor-level isolation.

## Architecture

```
┌──────────────────────────────────────────────────┐
│          Docker AI Sandbox (microVM)             │
│                                                  │
│  ┌────────────────────────────────────────────┐  │
│  │       OpenClaw Gateway (:18789)            │  │
│  │  ┌──────────┐ ┌────────┐ ┌──────────┐     │  │
│  │  │ Telegram  │ │Pi Agent│ │  Skills  │     │  │
│  │  │ (grammY)  │ │Runtime │ │ Platform │     │  │
│  │  └──────────┘ └────────┘ └──────────┘     │  │
│  │  ┌──────────┐ ┌────────┐ ┌──────────┐     │  │
│  │  │  Cron    │ │ Memory │ │ Browser  │     │  │
│  │  └──────────┘ └────────┘ └──────────┘     │  │
│  └────────────────────────────────────────────┘  │
│                                                  │
│  ~/.openclaw/openclaw.json  (config)             │
│  ~/.openclaw/workspace/     (personality)        │
│  Bidirectional file sync <-> host workspace      │
└──────────────────────────────────────────────────┘
        │                           │
        │ HTTPS                     │ HTTPS
        ▼                           ▼
  api.telegram.org           openrouter.ai
```

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) 4.58+ (with AI Sandbox support)
- [OpenRouter API key](https://openrouter.ai/) (recommended) or
  [Anthropic API key](https://console.anthropic.com/)
- [Telegram bot token](https://t.me/BotFather) (create via `/newbot`) — must be a **dedicated**
  token not used by any other running bot

## Quick Start

```bash
# 1. Configure secrets
cp .env.example .env
# Edit .env — set OPENROUTER_API_KEY (or ANTHROPIC_API_KEY) and TELEGRAM_BOT_TOKEN
# Set TELEGRAM_ALLOWED_IDS to your Telegram user ID (find it via @userinfobot)
```

```bash
# 2. Build template + create sandbox + start gateway
make up
# Takes ~2min on first run (downloads base image + installs Node 22 + Chromium + OpenClaw)
# Subsequent runs use cached layers and finish in seconds
```

```bash
# 3. DM your bot on Telegram — it responds immediately
# (Only users in TELEGRAM_ALLOWED_IDS can message it)
```

## Remote Deployment (Fly.io)

Run the bot on a Fly.io VM with a persistent volume. Optional Tailscale for private SSH access.

### First-Time Setup

```bash
# 1. Generate fly.toml
make fly-init APP=clawd

# 2. Set secrets
fly secrets set \
    OPENROUTER_API_KEY='sk-or-...' \
    TELEGRAM_BOT_TOKEN='123456:ABC-DEF...' \
    OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 16)" \
    TELEGRAM_ALLOWED_IDS='12345678' \
    -a clawd

# 3. Deploy
make deploy
```

### Subsequent Deploys

After editing `config/openclaw.json`, `config/workspace/*.md`, or `remote/*`:

```bash
make deploy
```

### Tailscale (Optional)

For private SSH access without `fly ssh console`, set a Tailscale auth key:

```bash
fly secrets set TAILSCALE_AUTHKEY='tskey-auth-...' -a clawd
make deploy
```

The VM will appear on your tailnet as `clawd` with Tailscale SSH enabled.

## Changing the Model

The model is set in `config/openclaw.json` under `agents.defaults.model.primary`.

For **OpenRouter**, prefix the model slug with `openrouter/`:

```json
"agents": {
  "defaults": {
    "model": {
      "primary": "openrouter/anthropic/claude-opus-4.5"
    }
  }
}
```

To see all available models, run `make shell` then
`openclaw models list --all --provider openrouter`.

Common OpenRouter model IDs:

| Model             | OpenClaw value                           |
| ----------------- | ---------------------------------------- |
| Claude Opus 4.5   | `openrouter/anthropic/claude-opus-4.5`   |
| Claude Opus 4.1   | `openrouter/anthropic/claude-opus-4.1`   |
| Claude Sonnet 4.5 | `openrouter/anthropic/claude-sonnet-4.5` |
| Claude Sonnet 4   | `openrouter/anthropic/claude-sonnet-4`   |
| Claude Haiku 4.5  | `openrouter/anthropic/claude-haiku-4.5`  |

For **direct Anthropic**, use the model ID without a prefix (e.g.
`anthropic/claude-sonnet-4-20250514`).

Note: OpenClaw maintains its own model catalog. New models from OpenRouter may not appear
immediately — check `openclaw models list --all` for what's currently supported.

After changing the model, run `make reset` to apply.

## Commands

| Command                    | Description                            |
| -------------------------- | -------------------------------------- |
| `make build`               | Build custom sandbox template          |
| `make up`                  | Build + create sandbox + start gateway |
| `make down`                | Stop sandbox                           |
| `make shell`               | Interactive shell in sandbox           |
| `make logs`                | Tail OpenClaw gateway logs             |
| `make status`              | Check sandbox and gateway health       |
| `make reset`               | Destroy and recreate sandbox           |
| `make onboard`             | Run OpenClaw onboarding wizard         |
| `make network-setup`       | Apply network proxy rules              |
| **Remote (Fly.io)**        |                                        |
| `make fly-init APP=<name>` | Generate `fly.toml` from template      |
| `make deploy`              | Deploy to Fly.io                       |
| `make fly-logs`            | Tail remote logs                       |
| `make fly-status`          | Check remote VM status                 |
| `make fly-console`         | SSH into remote VM                     |

## Repo Structure

```
clawd/
├── Makefile                      # Primary interface
├── .env.example                  # Secret template (copy to .env)
├── CLAUDE.md                     # Claude Code instructions
├── AGENTS.md                     # Generic agent instructions (Codex, etc.)
├── CODEX.md                      # Codex CLI instructions
│
├── template/
│   └── Dockerfile                # Sandbox template (claude-code + Node 22 + Chromium + OpenClaw)
│
├── config/
│   ├── openclaw.json             # Gateway config (no secrets)
│   └── workspace/
│       ├── AGENTS.md             # Bot personality (injected into OpenClaw)
│       ├── SOUL.md               # Bot identity
│       └── skills/               # Custom skills (injected into OpenClaw)
│
├── scripts/
│   ├── sandbox-up.sh             # Create sandbox, copy config, start gateway
│   ├── sandbox-down.sh           # Stop sandbox
│   ├── sandbox-status.sh         # Health check
│   ├── sandbox-logs.sh           # Tail gateway logs
│   └── network-policy.sh         # Deny-by-default network rules
│
└── remote/
    ├── Dockerfile                # Standalone image for Fly.io
    ├── entrypoint.sh             # VM init + gateway startup
    ├── fly.toml.example          # Fly.io config template
    ├── fly-init.sh               # Generate fly.toml from template
    └── deploy.sh                 # Validate secrets + fly deploy
```

## How It Works

**What runs inside the sandbox:** The Docker AI Sandbox is a microVM (not a container) with
hypervisor-level isolation. Inside it, the OpenClaw gateway runs as a long-lived process handling
Telegram messages, agent sessions, tools, and cron jobs. Chromium is installed for browser
automation.

**Secrets flow:** `.env` (host, gitignored) → shell environment → `docker sandbox exec -e` →
OpenClaw process. API keys are also registered in the agent auth store via `openclaw onboard` during
startup. Secrets never touch committed files.

**Telegram access control:** Uses `dmPolicy: "allowlist"` — only Telegram user IDs listed in
`TELEGRAM_ALLOWED_IDS` (in `.env`) can message the bot. IDs are injected into the config at startup
by `sandbox-up.sh`.

**Network policy:** Deny-by-default with an explicit allowlist: `openrouter.ai`,
`api.anthropic.com`, `api.telegram.org`, `*.npmjs.org`, `github.com`. Configured via
`scripts/network-policy.sh`.

**State persistence:** Sessions and cron jobs are snapshotted to `state/` (gitignored) on
`make down` and restored on `make up`. This means `make reset` preserves your state — no need to
re-configure every time.

## Troubleshooting

**409 Conflict: terminated by other getUpdates request** Another process is polling with the same
bot token. Each Telegram bot token can only have one `getUpdates` consumer. Fix: use a dedicated
token (create a new bot via [@BotFather](https://t.me/BotFather)), or clear a stale webhook and
restart:

```bash
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true"
make reset
```

**Bot doesn't respond to DMs** Check that your Telegram user ID is in `TELEGRAM_ALLOWED_IDS` in
`.env`. Find your ID by messaging [@userinfobot](https://t.me/userinfobot) on Telegram. After
updating `.env`, run `make reset`.

**"Telegram configured, not enabled yet" during `make up`** This is normal. The
`openclaw doctor --fix` step reports this before the gateway starts. Once the gateway is running,
Telegram is active. Confirm with `make logs`.

**Gateway token changes on every `make up`** A token is auto-generated if `OPENCLAW_GATEWAY_TOKEN`
is not in `.env`. To persist it, copy the generated value into your `.env`:

```bash
OPENCLAW_GATEWAY_TOKEN=<value from make up output>
```

## Roadmap

- **Phase 1** (done): Local Docker AI Sandbox on macOS
- **Phase 2** (done): Security hardening (allowlist), skills plumbing, Chromium, OpenRouter support
- **Phase 3** (done): Remote — Fly.io VM + Tailscale

## Links

- [OpenClaw docs](https://docs.openclaw.ai)
- [Gateway configuration](https://docs.openclaw.ai/gateway/configuration)
- [Telegram channel](https://docs.openclaw.ai/channels/telegram)
- [Skills](https://docs.openclaw.ai/tools/skills)
- [Docker AI Sandboxes](https://docs.docker.com/ai/sandboxes/)
