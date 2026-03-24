# TOOLS.md

## GitHub

- SSH key: ed25519, authenticated as `dtbuchholz`
- GH CLI: authenticated via `GH_TOKEN` (scopes: repo, admin:public_key, read:org)
- Commit signing: SSH-based, `commit.gpgsign = true`
- Git identity: Dan Buchholz <dbuchholz30@gmail.com>

## VM Environment

- **Platform:** Fly.io — Debian 12 (bookworm), `shared-cpu-4x`
- **CPU:** 4 vCPU (shared, AMD EPYC)
- **RAM:** 8GB (~6.5GB available after OS + gateway + browser)
- **Persistent volume:** `/data` (10GB), symlinked to `~/.openclaw`
- **Tailscale:** active, hostname `clawd`, SSH enabled
- **IP:** Datacenter (Datacamp Limited) — not suitable for residential-IP tasks
- **Browser:** Chromium, headless, `--no-sandbox`, CDP on port 18800
- **Python:** 3.11 (pip installed manually — not persisted across deploys)
- **Node:** 22

### What fits in these resources

- QMD memory search (3 GGUF models ~2GB) — ✅ fits now
- JS monorepo builds (Next.js, Turborepo) — ✅
- Light ML inference (CLIP, MobileNet) — ✅
- Multiple browser contexts — ✅
- PyTorch + fine-tuning — ❌ needs GPU, defer to cloud
- Large LLM local inference (7B+) — ⚠️ tight, would consume most RAM

## Tailscale Peers

- `daniels-macbook-pro` (macOS)
- `iphone181` (iOS)
- `agent-box` (Linux)
