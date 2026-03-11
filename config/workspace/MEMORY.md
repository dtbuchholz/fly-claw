# MEMORY.md — Active State

_Last updated: 2026-03-09_

## Tars Accounts & Identity

- **Gmail** — credentials in secrets (email + password)
- **GitHub** — separate account (same email/password as Gmail). Not yet integrated — still using Dan's personal `dtbuchholz` auth/PAT for git operations.
- **Twitter/X** — profile created, same email as Gmail but different password (separate secret)
- **EVM wallet** — `0xfEe29d962502c1CfA5D993244f9Ca2622b8e2843`, ~$50 USDC on Ethereum

## Infrastructure

- **VM:** Fly.io, 4 vCPU, 8GB RAM, 10GB disk, Debian 12, Tailscale (`clawd`)
- **Model:** Opus 4.6 (primary, Anthropic direct), Sonnet 4.5 (cron jobs)
- **Search:** Perplexity Sonar Pro via OpenRouter
- **Channels:** Telegram DM, Telegram forum group ("Tars HQ", ID: -1003782901451), Slack
- **Cron:** daily security audit (9am ET), daily state sync (10am ET), working-context snapshots, weekly memory rollup
- **Memory:** QMD backend (BM25+vector), indexed paths: journal/, patterns/, docs/, conversations/, research/
- **Context:** 200k token limit, cache-ttl pruning (5m), compaction with 30k reserve floor, memory flush at 4k tokens
- **Session reset:** idle mode, 180 min timeout
- **ACP:** Codex ✅ working, Claude ❌ blocked by upstream PTY issue (OpenClaw #28786)
- **Skills:** ~30 shared skills synced via `CLAUDE_CONFIG_REPO` / `CODEX_CONFIG_REPO` env vars
- **Tools:** summarize CLI, ffmpeg, yt-dlp, Chromium (headless)

## Key Decisions

- **Reasoning memory system:** journals for deep reasoning, patterns extracted after 5+, facts in memory/
- **Multi-session architecture:** Telegram DM/forum topics/Slack = isolated sessions, shared memory/workspace/cron
- **Channel briefs:** per-session `memory/channel-brief-<safeSessionKey>.md` files for permanent channel context, auto-created on first description
- **Skill bundling:** skills go in `config/workspace/skills/<name>/SKILL.md` in fly-claw, seeded to workspace on boot
- **Anthropic direct:** switched from OpenRouter (cost disaster — $16/2 requests) to direct Anthropic subscription (2026-03-01)
- **Telegram migration:** considering moving from forum group topics to separate Slack channels for better UX (notifications, no "General" channel noise)
