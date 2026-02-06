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
  api.telegram.org           api.anthropic.com
```

## Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) 4.58+ (with AI Sandbox support)
- [Anthropic API key](https://console.anthropic.com/)
- [Telegram bot token](https://t.me/BotFather) (create via `/newbot`) — must be a **dedicated** token not used by any other running bot

## Quick Start

```bash
# 1. Configure secrets
cp .env.example .env
# Edit .env — set ANTHROPIC_API_KEY and TELEGRAM_BOT_TOKEN
```

```bash
# 2. Build template + create sandbox + start gateway
make up
# Takes ~30s on first run (downloads base image + installs Node 22 + OpenClaw)
# Subsequent runs use cached layers and finish in seconds
```

```bash
# 3. DM your bot on Telegram
# It will reply with a pairing code and your Telegram user ID:
#   "Pairing code: XXXXXXXX"
#   "Ask the bot owner to approve with: openclaw pairing approve telegram <code>"
```

```bash
# 4. Approve the pairing from inside the sandbox
make shell
openclaw pairing approve telegram <CODE>
exit
```

```bash
# 5. Chat — your bot now responds to messages
```

## Commands

| Command              | Description                         |
| -------------------- | ----------------------------------- |
| `make build`         | Build custom sandbox template       |
| `make up`            | Build + create sandbox + start gateway |
| `make down`          | Stop sandbox                        |
| `make shell`         | Interactive shell in sandbox        |
| `make logs`          | Tail OpenClaw gateway logs          |
| `make status`        | Check sandbox and gateway health    |
| `make reset`         | Destroy and recreate sandbox        |
| `make onboard`       | Run OpenClaw onboarding wizard      |
| `make network-setup` | Apply network proxy rules           |

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
│   └── Dockerfile                # Sandbox template (claude-code + Node 22 + OpenClaw)
│
├── config/
│   ├── openclaw.json             # Gateway config (no secrets)
│   └── workspace/
│       ├── AGENTS.md             # Bot personality (injected into OpenClaw)
│       └── SOUL.md               # Bot identity
│
└── scripts/
    ├── sandbox-up.sh             # Create sandbox, copy config, start gateway
    ├── sandbox-down.sh           # Stop sandbox
    ├── sandbox-status.sh         # Health check
    ├── sandbox-logs.sh           # Tail gateway logs
    └── network-policy.sh         # Deny-by-default network rules
```

## How It Works

**What runs inside the sandbox:** The Docker AI Sandbox is a microVM (not a container) with
hypervisor-level isolation. Inside it, the OpenClaw gateway runs as a long-lived process handling
Telegram messages, agent sessions, tools, and cron jobs.

**Secrets flow:** `.env` (host, gitignored) → shell environment → `docker sandbox exec -e` →
OpenClaw process. Secrets never touch committed files or the sandbox filesystem.

**Network policy:** Deny-by-default with an explicit allowlist: `api.anthropic.com`,
`api.telegram.org`, `*.npmjs.org`, `github.com`. Configured via `scripts/network-policy.sh`.

**State persistence:** Telegram pairing, sessions, and cron jobs are snapshotted to `state/`
(gitignored) on `make down` and restored on `make up`. This means `make reset` preserves your
pairing — no need to re-pair every time.

## Troubleshooting

**409 Conflict: terminated by other getUpdates request**
Another process is polling with the same bot token. Each Telegram bot token can only have one
`getUpdates` consumer. Fix: use a dedicated token (create a new bot via [@BotFather](https://t.me/BotFather)),
or clear a stale webhook and restart:

```bash
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/deleteWebhook?drop_pending_updates=true"
make reset
```

**Bot doesn't respond to DMs**
Pairing is required on first contact. DM the bot — it will reply with a pairing code. Approve it:

```bash
make shell
openclaw pairing approve telegram <CODE>
exit
```

**"Telegram configured, not enabled yet" during `make up`**
This is normal. The `openclaw doctor --fix` step reports this before the gateway starts.
Once the gateway is running, Telegram is active. Confirm with `make logs`.

**Gateway token changes on every `make up`**
A token is auto-generated if `OPENCLAW_GATEWAY_TOKEN` is not in `.env`. To persist it, copy the
generated value into your `.env`:

```bash
OPENCLAW_GATEWAY_TOKEN=<value from make up output>
```

## Roadmap

- **Phase 1** (current): Local Docker AI Sandbox on macOS
- **Phase 2**: Polish — persistent state snapshots, skills, security hardening, cron
- **Phase 3**: Remote — Fly.io VM + Tailscale, borrowing patterns from [codebox](https://github.com)

## Links

- [OpenClaw docs](https://docs.openclaw.ai)
- [Gateway configuration](https://docs.openclaw.ai/gateway/configuration)
- [Telegram channel](https://docs.openclaw.ai/channels/telegram)
- [Skills](https://docs.openclaw.ai/tools/skills)
- [Docker AI Sandboxes](https://docs.docker.com/ai/sandboxes/)
