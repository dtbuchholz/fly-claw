# Clawd

Personal AI assistant (OpenClaw) running in a Docker AI Sandbox (local) or Fly.io VM (remote).

## Architecture

### Local (Docker Sandbox)

- `template/Dockerfile` - Custom sandbox template extending `docker/sandbox-templates:claude-code`
- `config/openclaw.json` - OpenClaw gateway config (no secrets)
- `config/workspace/` - Agent personality files (AGENTS.md, SOUL.md), skills, and scripts
- `config/cron/` - Default cron job definitions (seeded on first boot)
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
6. **Dockerfile binaries**: `RUN` executes as root, so installers that place binaries in `$HOME` (e.g. `/root/.bun/bin/`, `/root/.cargo/bin/`) won't be accessible to the `agent` user at runtime. Always `cp` binaries to `/usr/local/bin/` instead of symlinking to root's home. For packages with module trees (not standalone binaries), use `npm install -g` instead of `bun install -g` — npm places modules in `/usr/local/lib/node_modules/` with correct wrappers, while bun creates self-referential launcher scripts that break when copied out of `~/.bun/`.
7. **Native build deps**: Packages with native addons (e.g. `node-llama-cpp` in QMD) need `g++` and `make` in the image, plus write permissions on their build directories (`chmod -R a+w`) since the gateway runs as the non-root `agent` user.

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

## ACP Harnesses

The image includes [Claude Code](https://www.npmjs.com/package/@anthropic-ai/claude-code) and [Codex](https://www.npmjs.com/package/@openai/codex) CLIs so OpenClaw can spawn coding agent sessions via ACP.

**Config:** `acp` section in `config/openclaw.json`:

```json
{
  "acp": {
    "defaultAgent": "codex",
    "allowedAgents": ["codex", "claude"]
  }
}
```

**Required env vars:** `ANTHROPIC_API_KEY` (for Claude Code), `OPENAI_API_KEY` (for Codex) — set as Fly secrets.

**CLI config:** Each harness has its own config directory, persisted on `/data` and symlinked into the agent home:

- **Claude Code** — `/data/.claude/` (symlinked to `~/.claude/`). Seeded from `CLAUDE_CONFIG_REPO` with `settings.json`, `hooks/`, `skills/`, `agents/`.
- **Codex** — `/data/.codex/` (symlinked to `~/.codex/`). Seeded from `CODEX_CONFIG_REPO` with `config.toml`, `hooks/`, `skills/`, `agents/`, `policy/`.

See [Skills Sync](#skills-sync) for how config repos are seeded.

## Hooks

OpenClaw's internal hooks system provides lifecycle automation.

**Config:** `hooks.internal.enabled: true` in `config/openclaw.json` enables the hook system. Two hooks are enabled on every boot via `openclaw hooks enable`:

- **`session-memory`** — auto-saves conversation context to memory on `/new` or `/reset`
- **`boot-md`** — runs `BOOT.md` instructions on gateway startup (post-deploy verification)

## Skills Sync

Three layers of config/skills are seeded on deploy, each from a different source:

**Layer 1: OpenClaw workspace skills** — Skills the OpenClaw agent uses directly (`workspace/skills/`). Sourced from the `skills/` directory of the Claude config repo.

**Layer 2: Claude Code CLI config** — Global config for ACP Claude Code sessions (`~/.claude/`). Includes `settings.json`, hooks, skills, and agents.

**Layer 3: Codex CLI config** — Global config for ACP Codex sessions (`~/.codex/`). Includes `config.toml`, hooks, skills, agents, and policy.

**Env vars (Fly secrets):**

| Var                  | Default                                           | Purpose                 |
| -------------------- | ------------------------------------------------- | ----------------------- |
| `CLAUDE_CONFIG_REPO` | `https://github.com/dtbuchholz/claude-config.git` | Source for Layers 1 + 2 |
| `CODEX_CONFIG_REPO`  | `https://github.com/dtbuchholz/codex-config.git`  | Source for Layer 3      |

**Seeding behavior:**

- Repos are cloned via HTTPS on every deploy (uses `GH_TOKEN` for auth if set)
- Root config files (`settings.json`, `config.toml`) are seeded once — never overwritten
- Subdirectories (`hooks/`, `skills/`, `agents/`, `policy/`) use per-item merge: new items are added, existing items are preserved
- State-repo restore runs after seeding and overrides everything

## Cron Jobs

Fresh deployments are seeded with 4 default cron jobs. These run inside the OpenClaw agent (not system crontab) — the gateway's built-in scheduler executes them as agent prompts.

**Default jobs:**

| Job                     | Schedule (UTC) | Purpose                                                 |
| ----------------------- | -------------- | ------------------------------------------------------- |
| `daily-security-audit`  | 14:00 daily    | Runs `security-audit.sh`, reports only if issues found  |
| `daily-state-sync`      | 15:00 daily    | Runs `state-sync.sh` wrapper for agent-level visibility |
| `daily-memory-snapshot` | 08:00 daily    | Reviews last 24h, writes to memory if notable           |
| `weekly-memory-rollup`  | Fri 08:30      | Consolidates the week's memory entries                  |

**Config:** `config/cron/jobs.json` — uses OpenClaw's native format (`{"version":1,"jobs":[...]}`). Each job has a pre-generated UUID that the gateway preserves.

**Model override:** Jobs default to `openrouter/anthropic/claude-sonnet-4.5`. Set `CRON_MODEL` as a Fly secret to use a different model (e.g. `CRON_MODEL=openrouter/anthropic/claude-opus-4.5`). The entrypoint substitutes this at seed time via `jq`.

**Seeding behavior:**

- Only seeds when `/data/.openclaw/cron/jobs.json` doesn't exist (first boot)
- State-repo restore runs _after_ seeding, so backed-up cron state always takes priority
- Existing VMs are never affected — the seed is skipped entirely if the file exists
- Once seeded, the agent can modify jobs freely via the gateway; changes persist on the `/data` volume

**Scripts:** The cron jobs reference two shell scripts seeded into the agent's workspace:

- `scripts/security-audit.sh` — checks gateway bind, auth mode, file perms, disk usage, Tailscale, unexpected ports. Exits 0 (silent) or 1 (with details).
- `scripts/state-sync.sh` — thin wrapper that sources secrets and delegates to `/usr/local/bin/state-sync.sh`.

Scripts are also seeded with "don't overwrite" semantics — the agent can customize them and changes survive redeploys.

## QMD Memory Backend

Uses [QMD](https://docs.openclaw.ai/concepts/memory#qmd-backend-experimental) for semantic memory search (BM25 + vector embeddings + LLM reranking).

**Config:** Top-level `memory` key in `config/openclaw.json` — NOT under `agents.defaults`. Valid top-level config keys are strict; unknown keys cause `"Config invalid"`.

**Runtime deps:**

- **Bun** — required by QMD at runtime; installed via `curl` and copied to `/usr/local/bin/`
- **QMD CLI** (`@tobilu/qmd`) — installed via `npm install -g` (not `bun install -g`; see guideline #6)
- **g++ / make** — required for `node-llama-cpp` native CPU backend build
- **node-llama-cpp permissions** — `chmod -R a+w` on its directory so the `agent` user can trigger the build

**Entrypoint:** A background warmup job runs `qmd embed` 30 seconds after boot to pre-download GGUF models (~2GB, cached on `/data` volume) and generate embeddings. Without this, the first `memory_search` call would be very slow.

**Logs:** `/data/logs/qmd-warmup.log`

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
