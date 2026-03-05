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
- `remote/fly.toml.example` - Fly.io config template with `{{APP_NAME}}`/`{{REGION}}` placeholders; sets `NODE_ENV=production` and `OPENCLAW_STATE_DIR=/data/.openclaw` in `[env]`
- `remote/fly-init.sh` - Generates `fly.toml` from template
- `remote/deploy.sh` - Validates secrets, creates app/volume if needed, runs `fly deploy`
- `remote/vm-setup.sh` - Interactive wizard for git identity, SSH keys, commit signing, GitHub CLI
- `remote/acp-auth.sh` - Interactive OAuth setup for Claude Code + Codex ACP harnesses
- `.github/workflows/deploy.yml` - CI auto-deploy to Fly.io on pushes to `main` (triggered by `remote/`, `config/` changes)

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

Anthropic subscription is the primary provider. OpenRouter is kept as secondary for non-Anthropic models (GPT, Gemini, etc.). Set credentials in `.env`:

- **Anthropic subscription (recommended)**: `CLAUDE_CODE_OAUTH_TOKEN=sk-ant-oat-...` — generate with `claude setup-token`. Reuses your Pro/Max plan instead of per-token billing. Model IDs use `anthropic/` prefix (e.g. `anthropic/claude-opus-4-6`). Caveats: no prompt caching, no extended context (200K max), no cost tracking in OpenRouter dashboard.
- **Direct Anthropic API key**: `ANTHROPIC_API_KEY=sk-ant-...` — same `anthropic/` prefix model IDs. Standard per-token billing with prompt caching and full context support.
- **OpenRouter (secondary)**: `OPENROUTER_API_KEY=sk-or-...` — for non-Anthropic models only. Model IDs use `openrouter/` prefix (e.g. `openrouter/openai/gpt-5.2-codex`).

Auth priority: setup-token > Anthropic API key > OpenRouter. If setup-token onboarding fails and `ANTHROPIC_API_KEY` is present, the scripts automatically fall back to the API key path. Both Anthropic and OpenRouter can be registered simultaneously (the gateway routes based on model prefix). The model is configured in `config/openclaw.json` at `agents.defaults.model.primary`.

If only `OPENROUTER_API_KEY` is set (no Anthropic credentials), startup scripts override the default primary model to `openrouter/openai/gpt-5.2-codex` to avoid booting with an unauthenticated Anthropic default.

## Context Management

Prevents token explosion in long-running Telegram threads. Configured in `config/openclaw.json` under `agents.defaults`:

- **`maxConcurrent: 4`** — allows up to 4 parallel agent runs (cron, Telegram, ACP); default is 1
- **`contextTokens: 200000`** — hard budget; the gateway compacts when approaching this limit
- **`compaction.reserveTokensFloor: 30000`** — keeps 30K tokens free for the next response
- **`compaction.memoryFlush`** — flushes compacted context to QMD memory before discarding
- **`contextPruning`** — `cache-ttl` mode clears old tool results after 5 minutes, keeping only the last 3 assistant turns intact. Large results are soft-trimmed to head+tail snippets.
- **`session.reset.mode: "idle"`** — auto-resets the session after 60 minutes of inactivity, preventing unbounded conversation growth

Useful runtime commands: `/status` (check context usage), `/compact` (force compaction), `/usage tokens` (token stats).

**Deploy behavior:** Normal deploys (`make deploy`) only force `model.primary` and `maxConcurrent` to match available credentials and official best practices — agent-managed settings like compaction mode, context budget, and session reset are left untouched. To overwrite all agent settings with the repo defaults, use `make deploy-force`. State-repo restores (fresh volumes) always apply the full patch to fix stale config. Stale gateway lock files (`gateway.*.lock`) are cleaned on every boot to prevent startup failures after machine crashes.

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

**Config:** `acp` section in `config/openclaw.json`. The `acpx` plugin must also be enabled in `plugins.entries` — without it, the gateway doctor auto-enables the plugin at runtime, triggering a restart loop. `permissionMode` must be `approve-all` since ACP sessions are non-interactive and cannot answer permission prompts (the default `approve-reads` causes Codex to fail silently):

```json
{
  "plugins": {
    "entries": {
      "acpx": {
        "enabled": true,
        "config": { "permissionMode": "approve-all" }
      }
    }
  },
  "acp": {
    "enabled": true,
    "dispatch": { "enabled": true },
    "backend": "acpx",
    "defaultAgent": "codex",
    "allowedAgents": ["codex", "claude"],
    "maxConcurrentSessions": 4,
    "stream": { "coalesceIdleMs": 300, "maxChunkChars": 1200 },
    "runtime": { "ttlMinutes": 120 }
  }
}
```

**Auth:** Each CLI uses OAuth rather than raw API keys. Run `make fly-auth` to set up both:

- **Claude Code** — `claude setup-token` generates a long-lived OAuth token (1 year). Set it as a Fly secret: `CLAUDE_CODE_OAUTH_TOKEN`. The CLI reads this from the environment automatically.
- **Codex** — `codex login --device-auth` does a device code flow (headless-friendly). Credentials are stored in `~/.codex/auth.json` on the persistent volume, using ChatGPT OAuth with auto-refresh. A wrapper script at `/usr/local/bin/codex` unsets `OPENAI_API_KEY` before invoking the preserved binary (`/usr/local/bin/codex-real`) so the CLI uses OAuth instead of the API key. `OPENAI_API_KEY` remains available to other processes (TTS, etc.).

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

- Repos are cloned via HTTPS on every deploy (uses `GITHUB_TOKEN` or `GH_TOKEN` for auth if set)
- Root config files (`settings.json`, `config.toml`) are seeded once — never overwritten
- Subdirectories (`hooks/`, `skills/`, `agents/`, `policy/`) use per-item merge: new items are added, existing items are preserved
- State-repo restore runs after seeding and overrides everything

## Cron Jobs

Fresh deployments are seeded with 5 default cron jobs. These run inside the OpenClaw agent (not system crontab) — the gateway's built-in scheduler executes them as agent prompts.

**Default jobs:**

| Job                        | Schedule (UTC) | Purpose                                                                                                                                        |
| -------------------------- | -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `daily-security-audit`     | 14:00 daily    | Runs `security-audit.sh`, reports only if issues found                                                                                         |
| `daily-state-sync`         | 15:00 daily    | Runs `state-sync.sh` wrapper for agent-level visibility                                                                                        |
| `daily-memory-snapshot`    | 08:00 daily    | Reviews last 24h, writes to memory if notable                                                                                                  |
| `weekly-memory-rollup`     | Fri 08:30      | Consolidates the week's memory entries                                                                                                         |
| `working-context-snapshot` | Every 30 min   | Saves per-session context to `memory/working-context-<sessionKey>.md` and updates canonical `memory/working-context.md` for main/DM continuity |

**Config:** `config/cron/jobs.json` — uses OpenClaw's native format (`{"version":1,"jobs":[...]}`). Each job has a pre-generated UUID that the gateway preserves.

**Model override:** Jobs default to `anthropic/claude-sonnet-4-5`. Set `CRON_MODEL` as a Fly secret to use a different model (e.g. `CRON_MODEL=anthropic/claude-opus-4-6`). If only OpenRouter credentials are present, the entrypoint defaults cron to `openrouter/openai/gpt-5.2-codex` unless `CRON_MODEL` is explicitly set. `CRON_MODEL` replaces the default Sonnet model in seeded jobs; jobs that specify a different model (e.g. Haiku) are kept as-is. The entrypoint substitutes this at seed time via `jq`.

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

## Summarize CLI

Uses [@steipete/summarize](https://github.com/steipete/summarize) to extract and summarize content from URLs, YouTube videos, podcasts, audio/video files, and PDFs.

**Runtime deps:** `ffmpeg` (apt), `yt-dlp` (standalone binary), `@steipete/summarize` (npm global)

**Skill:** `config/workspace/skills/summarize/SKILL.md` — loaded by the gateway when `summarize` binary is present (`requires.bins`)

**Environment:** Uses whichever provider is configured (Anthropic subscription or OpenRouter). No additional secrets needed.

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
make fly-auth             # Set up OAuth for ACP harnesses
```

## OpenClaw Docs

- Gateway config: https://docs.openclaw.ai/gateway/configuration
- Telegram channel: https://docs.openclaw.ai/channels/telegram
- Skills: https://docs.openclaw.ai/tools/skills
