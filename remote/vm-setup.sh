#!/usr/bin/env bash
set -euo pipefail

# Interactive setup wizard for git, SSH, and GitHub CLI.
# Run once via SSH: ssh agent@<host> vm-setup
# State persists on /data volume across redeploys.

BOLD='\033[1m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

header()  { echo -e "\n${BOLD}=== $1 ===${RESET}\n"; }
ok()      { echo -e "${GREEN}✓ $1${RESET}"; }
warn()    { echo -e "${YELLOW}! $1${RESET}"; }

ask_yn() {
    local prompt="$1" default="${2:-y}"
    local yn
    if [ "$default" = "y" ]; then
        read -rp "$prompt [Y/n] " yn
        yn="${yn:-y}"
    else
        read -rp "$prompt [y/N] " yn
        yn="${yn:-n}"
    fi
    [[ "$yn" =~ ^[Yy] ]]
}

# ---------------------------------------------------------------------------
# 1. Git identity
# ---------------------------------------------------------------------------
header "Git Identity"

GIT_NAME=$(git config --global user.name 2>/dev/null || true)
GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)

if [ -n "$GIT_NAME" ] && [ -n "$GIT_EMAIL" ]; then
    ok "Already configured: $GIT_NAME <$GIT_EMAIL>"
    if ! ask_yn "Change it?" "n"; then
        SKIP_GIT_ID=true
    fi
fi

if [ "${SKIP_GIT_ID:-}" != "true" ]; then
    read -rp "Name: " new_name
    read -rp "Email: " new_email
    git config --global user.name "$new_name"
    git config --global user.email "$new_email"
    GIT_NAME="$new_name"
    GIT_EMAIL="$new_email"
    ok "Set: $GIT_NAME <$GIT_EMAIL>"
fi

# ---------------------------------------------------------------------------
# 2. SSH key
# ---------------------------------------------------------------------------
header "SSH Key"

SSH_KEY="$HOME/.ssh/id_ed25519"

if [ -f "$SSH_KEY" ]; then
    ok "Key exists: $SSH_KEY"
    echo "Public key:"
    cat "${SSH_KEY}.pub"
    echo ""
else
    if ask_yn "Generate an ed25519 SSH key?"; then
        ssh-keygen -t ed25519 -C "${GIT_EMAIL}" -f "$SSH_KEY" -N "" -q
        ok "Generated: $SSH_KEY"
        echo ""
        echo "Public key (add to GitHub as both Authentication and Signing key):"
        echo ""
        cat "${SSH_KEY}.pub"
        echo ""
    else
        warn "Skipped — git signing and private repo access won't work without a key"
    fi
fi

# ---------------------------------------------------------------------------
# 3. SSH commit signing
# ---------------------------------------------------------------------------
header "SSH Commit Signing"

CURRENT_FORMAT=$(git config --global gpg.format 2>/dev/null || true)

if [ "$CURRENT_FORMAT" = "ssh" ]; then
    ok "Already configured (gpg.format=ssh)"
    CURRENT_KEY=$(git config --global user.signingkey 2>/dev/null || true)
    [ -n "$CURRENT_KEY" ] && ok "Signing key: $CURRENT_KEY"
elif [ -f "$SSH_KEY" ]; then
    if ask_yn "Enable SSH commit signing?"; then
        git config --global gpg.format ssh
        git config --global user.signingkey "${SSH_KEY}.pub"
        git config --global commit.gpgsign true
        git config --global tag.gpgsign true

        # allowed_signers for local verification
        SIGNERS="$HOME/.ssh/allowed_signers"
        echo "${GIT_EMAIL} $(cat "${SSH_KEY}.pub")" > "$SIGNERS"
        git config --global gpg.ssh.allowedSignersFile "$SIGNERS"

        ok "Enabled — commits will be signed with ${SSH_KEY}.pub"
    fi
else
    warn "No SSH key found — skipping signing setup"
fi

# ---------------------------------------------------------------------------
# 4. GitHub CLI
# ---------------------------------------------------------------------------
header "GitHub CLI"

if gh auth status &>/dev/null; then
    ok "Already authenticated"
    gh auth status 2>&1 | head -5
else
    if ask_yn "Authenticate with GitHub?"; then
        echo ""
        echo "Choose: GitHub.com → SSH (or HTTPS) → Paste an authentication token"
        echo "(Create a token at https://github.com/settings/tokens with repo scope)"
        echo ""
        gh auth login
        gh auth setup-git
        ok "Authenticated + git credential helper configured"
    else
        warn "Skipped — gh commands and HTTPS cloning won't work without auth"
    fi
fi

# ---------------------------------------------------------------------------
# 5. SSH config for GitHub
# ---------------------------------------------------------------------------
header "SSH Config"

SSH_CONFIG="$HOME/.ssh/config"

if grep -q 'Host github.com' "$SSH_CONFIG" 2>/dev/null; then
    ok "GitHub SSH config already exists"
else
    if [ -f "$SSH_KEY" ]; then
        mkdir -p "$(dirname "$SSH_CONFIG")"
        cat >> "$SSH_CONFIG" <<'SSHEOF'
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
SSHEOF
        chmod 600 "$SSH_CONFIG"
        ok "Added github.com entry to ~/.ssh/config"
    else
        warn "No SSH key — skipping SSH config"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
header "Summary"

echo "Git:     $(git config --global user.name 2>/dev/null || echo 'not set') <$(git config --global user.email 2>/dev/null || echo 'not set')>"
echo "SSH key: $([ -f "$SSH_KEY" ] && echo "$SSH_KEY" || echo 'none')"
echo "Signing: $(git config --global gpg.format 2>/dev/null || echo 'off')"
echo "gh CLI:  $(gh auth status &>/dev/null && echo 'authenticated' || echo 'not authenticated')"
echo ""

if [ -f "${SSH_KEY}.pub" ]; then
    echo -e "${BOLD}Next steps on GitHub (https://github.com/settings/keys):${RESET}"
    echo ""
    echo "  1. Add as Authentication key (for cloning private repos):"
    echo "     → New SSH Key → Title: \"clawd\" → Key type: Authentication"
    echo ""
    echo "  2. Add as Signing key (for verified commits):"
    echo "     → New SSH Key → Title: \"clawd-signing\" → Key type: Signing"
    echo ""
    echo "  Public key to paste for both:"
    echo ""
    cat "${SSH_KEY}.pub"
    echo ""
fi

echo "All state is persisted on /data — survives redeploys."
