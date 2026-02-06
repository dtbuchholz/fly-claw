FROM docker/sandbox-templates:claude-code

USER root

# Upgrade Node.js to 22.x (base image ships 20.x, OpenClaw requires >=22.12)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Chromium for browser automation
RUN apt-get update && apt-get install -y --no-install-recommends \
    chromium \
    fonts-liberation \
    libnss3 \
    libatk-bridge2.0-0 \
    libdrm2 \
    libxcomposite1 \
    libxdamage1 \
    libxrandr2 \
    libgbm1 \
    libasound2t64 \
    libpangocairo-1.0-0 \
    libgtk-3-0 \
    && rm -rf /var/lib/apt/lists/*

ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true
ENV CHROMIUM_PATH=/usr/bin/chromium

# Install OpenClaw globally
RUN npm install -g openclaw@latest

# Create OpenClaw state and workspace directories
RUN mkdir -p /home/agent/.openclaw/workspace \
    && chown -R agent:agent /home/agent/.openclaw

USER agent
