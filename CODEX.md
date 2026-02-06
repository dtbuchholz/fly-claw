# CODEX.md

Guidance for Codex CLI when working on this repository.

## Project Overview

**Clawd** — OpenClaw personal AI assistant running in a Docker AI Sandbox. See [README.md](./README.md) for user documentation. Read [AGENTS.md](./AGENTS.md) for code style, repo structure, and architecture notes.

## Quick Reference

```bash
make build    # Build sandbox template
make up       # Create sandbox + start gateway
make down     # Stop sandbox
make shell    # Shell into sandbox
make logs     # Tail gateway logs
make status   # Health check
```

## Key Files

| File                        | Purpose                                            |
| --------------------------- | -------------------------------------------------- |
| `template/Dockerfile`       | Custom sandbox template (Node 22 + OpenClaw)       |
| `config/openclaw.json`      | OpenClaw gateway config (no secrets)               |
| `config/workspace/AGENTS.md`| Bot personality (injected into OpenClaw, not this!) |
| `scripts/sandbox-up.sh`     | Main orchestration: create sandbox + start gateway  |
| `scripts/network-policy.sh` | Deny-by-default network rules                      |
| `Makefile`                  | Primary interface for all operations               |

## Workflow

1. **Read AGENTS.md** for code style and project conventions
2. Run `make build` to verify the template builds after Dockerfile changes
3. Shell scripts use `set -euo pipefail` and quote all variables
4. Never put secrets in committed files — they live in `.env` (gitignored)
5. `config/workspace/AGENTS.md` is the OpenClaw bot personality — different from the repo-root `AGENTS.md`
