FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# System deps + Chromium + browser automation deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    git \
    jq \
    sudo \
    openssh-client \
    chromium \
    fonts-liberation \
    libnss3 \
    libatk-bridge2.0-0 \
    libdrm2 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libgbm1 \
    libasound2 \
    libpangocairo-1.0-0 \
    libgtk-3-0 \
    rsync \
    unzip \
    g++ \
    make \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        > /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22.x
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Tailscale
RUN curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
        > /usr/share/keyrings/tailscale-archive-keyring.gpg \
    && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
        > /etc/apt/sources.list.d/tailscale.list \
    && apt-get update && apt-get install -y --no-install-recommends tailscale \
    && rm -rf /var/lib/apt/lists/*

ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV CHROMIUM_PATH=/usr/bin/chromium

# Bun (required by QMD memory backend at runtime)
RUN curl -fsSL https://bun.sh/install | bash \
    && cp /root/.bun/bin/bun /usr/local/bin/bun \
    && cp /root/.bun/bin/bunx /usr/local/bin/bunx \
    && rm -rf /root/.bun

# OpenClaw + QMD memory backend
# chmod: node-llama-cpp needs write access for CPU backend build at runtime (runs as agent user)
RUN npm install -g openclaw@latest @tobilu/qmd@latest \
    && chmod -R a+w /usr/lib/node_modules/@tobilu/qmd/node_modules/node-llama-cpp/ \
    && chmod -R a+w /usr/lib/node_modules/openclaw/extensions/acpx/

# ACP harnesses (Claude Code + Codex CLIs for agent coding sessions)
RUN npm install -g @anthropic-ai/claude-code@latest @openai/codex@latest

# Codex wrapper: unset OPENAI_API_KEY so Codex uses OAuth (from codex login --device-auth)
# instead of the API key. OPENAI_API_KEY stays available for other processes (TTS, etc.).
# Real binary is at /usr/bin/codex; wrapper takes precedence via /usr/local/bin PATH order.
RUN printf '#!/bin/bash\nunset OPENAI_API_KEY\nexec /usr/bin/codex "$@"\n' \
        > /usr/local/bin/codex \
    && chmod +x /usr/local/bin/codex

# Non-root user with sudo
RUN groupadd -r agent && useradd -r -g agent -m -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent

# Bundle config, workspace, and cron defaults
COPY config/openclaw.json /opt/openclaw/openclaw.json
COPY config/workspace/ /opt/openclaw/workspace/
COPY config/cron/ /opt/openclaw/cron/

# Scripts
COPY remote/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY remote/vm-setup.sh /usr/local/bin/vm-setup.sh
COPY remote/state-sync.sh /usr/local/bin/state-sync.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/vm-setup.sh /usr/local/bin/state-sync.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD su - agent -c 'source /data/.env.secrets 2>/dev/null && openclaw health' || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
