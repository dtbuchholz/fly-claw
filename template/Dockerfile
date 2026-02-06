FROM docker/sandbox-templates:claude-code

USER root

# Upgrade Node.js to 22.x (base image ships 20.x, OpenClaw requires >=22.12)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install OpenClaw globally
RUN npm install -g openclaw@latest

# Create OpenClaw state and workspace directories
RUN mkdir -p /home/agent/.openclaw/workspace \
    && chown -R agent:agent /home/agent/.openclaw

USER agent
