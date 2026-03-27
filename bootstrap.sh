#!/bin/bash
# VirtualCC Bootstrap Script
# Provisions a blank Ubuntu 24.04 VPS into a persistent Claude Code environment.
#
# Usage:
#   ssh root@<vps-ip> 'curl -fsSL https://raw.githubusercontent.com/seanpatrickmay/virtualCC/main/bootstrap.sh -o /tmp/bootstrap.sh'
#   ssh root@<vps-ip> 'DEV_PASSWORD=yourpassword bash /tmp/bootstrap.sh'
#
# Environment variables:
#   DEV_PASSWORD  Password for the dev user (used for sudo). Random if not set.
#
# This script must be run as root.

set -euo pipefail

# --- Sanity checks ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root." >&2
    exit 1
fi

if ! grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
    echo "WARNING: This script is designed for Ubuntu 24.04. Proceeding anyway..."
fi

REPO_URL="https://github.com/seanpatrickmay/virtualCC.git"
DOTFILES_URL="https://github.com/seanpatrickmay/dotfiles.git"
DEV_USER="dev"
DEV_HOME="/home/$DEV_USER"
DEV_PASSWORD="${DEV_PASSWORD:-$(openssl rand -base64 32)}"
NVIM_VERSION="v0.11.4"
NVM_VERSION="v0.40.1"

# Step counter (auto-incrementing)
STEP=0; TOTAL=12
step() { STEP=$((STEP + 1)); echo "[$STEP/$TOTAL] $1"; }

# Install files from manifest. Reads config/manifest.txt and copies files.
# Usage: install_manifest <manifest_path> <home_dir> <mode_filter>
install_manifest() {
    local manifest="$1" home="$2" filter="$3" vccdir="$4"
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Parse tab or multi-space separated fields
        local src dest mode
        src=$(echo "$line" | awk '{print $1}')
        dest=$(echo "$line" | awk '{print $2}')
        mode=$(echo "$line" | awk '{print $3}')
        dest="${dest/#\~/$home}"
        [[ "$mode" != "$filter" ]] && continue

        local src_path="$vccdir/$src"
        [ -f "$src_path" ] || continue
        mkdir -p "$(dirname "$dest")"

        case "$mode" in
            json-merge)
                if [ -f "$dest" ] && command -v jq &>/dev/null; then
                    if jq -s '.[0] * .[1]' "$src_path" "$dest" > "$dest.tmp" 2>/dev/null; then
                        mv "$dest.tmp" "$dest"
                    else
                        rm -f "$dest.tmp"
                        cp "$src_path" "$dest"
                    fi
                else
                    cp "$src_path" "$dest"
                fi
                ;;
            bootstrap-only)
                [ -f "$dest" ] || cp "$src_path" "$dest"
                ;;
            +x)
                cp "$src_path" "$dest"
                chmod +x "$dest"
                ;;
            *)
                cp "$src_path" "$dest"
                ;;
        esac
    done < "$manifest"
}

echo "========================================="
echo "VirtualCC Bootstrap — Phase 1: System Setup"
echo "========================================="

step "Installing system packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl build-essential zsh tmux unzip python3 openssl ufw fail2ban at logrotate mosh jq

# Install neovim from GitHub releases (apt version is too old for plugins)
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    NVIM_ARCH="linux-x86_64"
elif [ "$ARCH" = "aarch64" ]; then
    NVIM_ARCH="linux-arm64"
else
    echo "ERROR: Unsupported architecture: $ARCH (need x86_64 or aarch64)" >&2
    exit 1
fi
if ! nvim --version 2>/dev/null | grep -q "${NVIM_VERSION#v}"; then
    curl -Lo /tmp/nvim.tar.gz \
        "https://github.com/neovim/neovim/releases/download/$NVIM_VERSION/nvim-$NVIM_ARCH.tar.gz"
    rm -rf /opt/nvim
    tar xzf /tmp/nvim.tar.gz -C /opt
    ln -sf "/opt/nvim-$NVIM_ARCH/bin/nvim" /usr/local/bin/nvim
    rm /tmp/nvim.tar.gz
fi

# Install GitHub CLI (used by Claude Code for PR/issue workflows)
if ! command -v gh &>/dev/null; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list
    apt-get update
    apt-get install -y gh
fi

# Ensure atd is running (needed for SSH hardening safety rollback)
systemctl enable atd
systemctl start atd

# Set up swap if not present (2GB for 4 concurrent Claude sessions)
if ! swapon --show | grep -q "/swapfile"; then
    echo "[*] Creating 2GB swap file..."
    if [ ! -f /swapfile ]; then
        fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
        chmod 600 /swapfile
        mkswap /swapfile
    fi
    swapon /swapfile
    grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
    # Prefer RAM, only swap under pressure
    sysctl vm.swappiness=10
    grep -q "vm.swappiness" /etc/sysctl.conf || echo "vm.swappiness=10" >> /etc/sysctl.conf
fi

# Step 2: Firewall
step "Configuring firewall..."
ufw allow ssh
ufw allow 60000:60010/udp  # mosh (UDP for mobile connections)
ufw --force enable

# Step 3: Create dev user (idempotent — safe to re-run)
step "Creating dev user..."
if ! id "$DEV_USER" &>/dev/null; then
    useradd -m -s /usr/bin/zsh "$DEV_USER"
fi
# Always ensure correct group, shell, and password (fixes re-runs with existing user)
usermod -aG sudo "$DEV_USER"
chsh -s /usr/bin/zsh "$DEV_USER" 2>/dev/null || true
echo "$DEV_USER:$DEV_PASSWORD" | chpasswd
# Save password for reference (root-only readable)
echo "$DEV_PASSWORD" > /root/.vcc-dev-password
chmod 600 /root/.vcc-dev-password

# Copy SSH keys from root to dev
echo "  Copying SSH keys to dev user..."
mkdir -p "$DEV_HOME/.ssh"
cp /root/.ssh/authorized_keys "$DEV_HOME/.ssh/authorized_keys"
chown -R "$DEV_USER:$DEV_USER" "$DEV_HOME/.ssh"
chmod 700 "$DEV_HOME/.ssh"
chmod 600 "$DEV_HOME/.ssh/authorized_keys"

echo "========================================="
echo "VirtualCC Bootstrap — Phase 2: User Environment"
echo "========================================="

# Clone this repo for config files
echo "[*] Cloning virtualCC repo for config files..."
VCCDIR="$DEV_HOME/.local/share/virtualCC"
sudo -H -u "$DEV_USER" bash -c "mkdir -p '$DEV_HOME/.local/share' && git clone '$REPO_URL' '$VCCDIR'" 2>/dev/null || \
    sudo -H -u "$DEV_USER" bash -c "cd '$VCCDIR' && git pull"

# Step 4: Node.js via nvm
step "Installing nvm and Node.js..."
sudo -H -u "$DEV_USER" bash -c "
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh | bash
    export NVM_DIR=\$HOME/.nvm
    # shellcheck source=/dev/null
    source \$NVM_DIR/nvm.sh
    nvm install --lts
"

# Step 5: Claude Code
step "Installing Claude Code..."
sudo -H -u "$DEV_USER" bash -c '
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh"
    npm install -g @anthropic-ai/claude-code tree-sitter-cli
'

# Step 5b: Claude Code config (via manifest — JSON files merge, others bootstrap-only)
echo "  Installing Claude Code config..."
sudo -H -u "$DEV_USER" mkdir -p "$DEV_HOME/.claude"
install_manifest "$VCCDIR/config/manifest.txt" "$DEV_HOME" "json-merge" "$VCCDIR"
install_manifest "$VCCDIR/config/manifest.txt" "$DEV_HOME" "bootstrap-only" "$VCCDIR"
# Install env template if no .env exists yet (don't overwrite user values)
[ -f "$DEV_HOME/.env" ] || sudo -H -u "$DEV_USER" cp "$VCCDIR/config/env.template" "$DEV_HOME/.env"

# Step 6: Oh My Zsh + Powerlevel10k
step "Installing Oh My Zsh and Powerlevel10k..."
# Download installer first, then run as dev user to avoid $() expanding as root
curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o /tmp/install-omz.sh
sudo -H -u "$DEV_USER" RUNZSH=no CHSH=no bash /tmp/install-omz.sh || true
rm -f /tmp/install-omz.sh
sudo -H -u "$DEV_USER" bash -c '
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
        "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
' 2>/dev/null || true
sudo -H -u "$DEV_USER" bash -c '
    git clone https://github.com/zsh-users/zsh-autosuggestions \
        "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions"
' 2>/dev/null || true
sudo -H -u "$DEV_USER" bash -c '
    git clone https://github.com/zsh-users/zsh-syntax-highlighting \
        "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting"
' 2>/dev/null || true

# Step 7: Dotfiles
step "Installing dotfiles..."
sudo -H -u "$DEV_USER" bash -c "git clone '$DOTFILES_URL' '$DEV_HOME/dotfiles'" 2>/dev/null || \
    sudo -H -u "$DEV_USER" bash -c "cd '$DEV_HOME/dotfiles' && git pull"

# Symlink dotfiles (force overwrite oh-my-zsh's .zshrc)
sudo -H -u "$DEV_USER" bash -c '
    ln -sf ~/dotfiles/.zshrc ~/.zshrc
    ln -sf ~/dotfiles/.p10k.zsh ~/.p10k.zsh
    ln -sf ~/dotfiles/.vimrc ~/.vimrc
    ln -sf ~/dotfiles/.tmux.conf ~/.tmux.conf
    mkdir -p ~/.config
    rm -rf ~/.config/nvim
    ln -sf ~/dotfiles/.config/nvim ~/.config/nvim
    rm -rf ~/.vim
    ln -sf ~/dotfiles/.vim ~/.vim
    rm -rf ~/.tmux
    ln -sf ~/dotfiles/.tmux ~/.tmux
'

# Install nvim plugins via git clone (PackerSync is unreliable in headless mode)
echo "  Installing nvim plugins..."
sudo -H -u "$DEV_USER" bash -c '
    D="$HOME/.local/share/nvim/site/pack/packer/start"
    mkdir -p "$D"
    clone() { [ -d "$D/$2" ] || git clone --depth 1 "https://github.com/$1" "$D/$2"; }
    clone wbthomason/packer.nvim packer.nvim
    clone nvim-telescope/telescope.nvim telescope.nvim
    clone nvim-lua/plenary.nvim plenary.nvim
    clone rose-pine/neovim rose-pine
    clone nvim-treesitter/nvim-treesitter nvim-treesitter
    clone mbbill/undotree undotree
    clone tpope/vim-fugitive vim-fugitive
    clone lervag/vimtex vimtex
    clone RRethy/vim-illuminate vim-illuminate
    clone nvim-tree/nvim-tree.lua nvim-tree.lua
    clone shellRaining/hlchunk.nvim hlchunk.nvim
    clone nvim-lualine/lualine.nvim lualine.nvim
    clone nvim-tree/nvim-web-devicons nvim-web-devicons
    clone OXY2DEV/markview.nvim markview.nvim
'
# Generate packer_compiled.lua
sudo -H -u "$DEV_USER" bash -c 'timeout 10 nvim --headless -c "PackerCompile" -c "quitall" 2>/dev/null' || true

# Pre-install treesitter parsers (avoids compile delay on first file open)
# Requires tree-sitter-cli (installed with Claude Code above) and gcc (build-essential).
# TSInstall runs async — sleep gives time for compilation before quitting.
echo "  Installing treesitter parsers..."
sudo -H -u "$DEV_USER" bash -c '
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh"
    timeout 180 nvim --headless \
        -c "TSInstall lua bash python javascript typescript c json html css yaml toml markdown vim vimdoc query markdown_inline" \
        -c "sleep 60" -c "quitall" 2>/dev/null
' || true

# Ensure dotfiles .zshrc sources .zshrc.local (required for nvm, env vars, server utilities).
# Appends the line only if missing. Safe for git pull --ff-only since the dotfiles repo
# should already have this line committed upstream.
sudo -H -u "$DEV_USER" bash -c '
    grep -q "zshrc.local" ~/dotfiles/.zshrc 2>/dev/null || \
        echo -e "\n# VCC: Source local config (nvm, env vars, server utilities)\n[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local" >> ~/dotfiles/.zshrc
'

# Step 8: tmux systemd service
step "Setting up tmux auto-start service..."
sudo -H -u "$DEV_USER" bash -c "
    mkdir -p ~/.local/bin
    cp '$VCCDIR/config/tmux-session.sh' ~/.local/bin/tmux-session.sh
    chmod +x ~/.local/bin/tmux-session.sh
    mkdir -p ~/.config/systemd/user
    cp '$VCCDIR/config/tmux-vcc.service' ~/.config/systemd/user/tmux-vcc.service
"

# Enable lingering and start the service
DEV_UID=$(id -u "$DEV_USER")
loginctl enable-linger "$DEV_USER"

# Ensure runtime directory and wait for user D-Bus socket
mkdir -p "/run/user/$DEV_UID"
chown "$DEV_USER:$DEV_USER" "/run/user/$DEV_UID"

echo "  Waiting for systemd user bus socket..."
for _ in $(seq 1 30); do
    [ -S "/run/user/$DEV_UID/bus" ] && break
    sleep 1
done

if [ ! -S "/run/user/$DEV_UID/bus" ]; then
    echo "WARNING: User bus socket not found after 30s. tmux service may need manual start."
else
    sudo -H -u "$DEV_USER" bash -c "
        export XDG_RUNTIME_DIR=/run/user/$DEV_UID
        export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$DEV_UID/bus
        systemctl --user daemon-reload
        systemctl --user enable tmux-vcc.service
        systemctl --user start tmux-vcc.service
    "
    echo "  tmux service started."
fi

# Step 9: Install shell config + logrotate (via manifest)
step "Installing shell configs..."
install_manifest "$VCCDIR/config/manifest.txt" "$DEV_HOME" "644" "$VCCDIR"

# Ensure .zprofile sources .zprofile.local
sudo -H -u "$DEV_USER" bash -c '
    touch ~/.zprofile
    grep -q "zprofile.local" ~/.zprofile 2>/dev/null || \
        echo "[[ -f ~/.zprofile.local ]] && source ~/.zprofile.local" >> ~/.zprofile
'

echo "========================================="
echo "VirtualCC Bootstrap — Phase 3: Finalization"
echo "========================================="

# Step 10: Cron jobs
step "Installing cron jobs..."

# Create required directories
sudo -H -u "$DEV_USER" bash -c "mkdir -p ~/.local/bin ~/.local/log/cron ~/.local/state ~/.local/backups ~/.config"

# Install all executable scripts from manifest
install_manifest "$VCCDIR/config/manifest.txt" "$DEV_HOME" "+x" "$VCCDIR"

# Root crontab: weekly system update (install to /usr/local/sbin for stable path)
cp "$VCCDIR/config/cron/update-system" /usr/local/sbin/vcc-update-system
chmod +x /usr/local/sbin/vcc-update-system
SYSTEM_CRON="0 3 * * 0 /usr/local/sbin/vcc-update-system"
# Disable errexit: crontab -l and grep -v both return 1 on empty input
set +e
(crontab -l 2>/dev/null | grep -v "update-system"; echo "$SYSTEM_CRON") | crontab -
set -e

# Dev user crontab
# Note: all variables are expanded in the root shell (double-quoted heredoc).
# The crontab receives the resolved paths, not variable references.
DEV_CRON_CLAUDE="30 3 * * 0 flock -n /tmp/vcc-update-claude.lock $DEV_HOME/.local/bin/update-claude"
DEV_CRON_DOTFILES="0 4 * * * flock -n /tmp/vcc-sync-dotfiles.lock $DEV_HOME/.local/bin/sync-dotfiles"
DEV_CRON_LOGROTATE="0 5 * * 0 /usr/sbin/logrotate --state $DEV_HOME/.local/state/logrotate.status $DEV_HOME/.config/logrotate.conf"
DEV_CRON_HEALTH="0 */6 * * * $DEV_HOME/.local/bin/health-check >> $DEV_HOME/.local/log/cron/health-check.log 2>&1"
DEV_CRON_VCCUPDATE="30 4 * * * flock -n /tmp/vcc-update.lock $DEV_HOME/.local/bin/vcc-update"
DEV_CRON_CLEANUP="0 2 * * 0 flock -n /tmp/vcc-disk-cleanup.lock $DEV_HOME/.local/bin/disk-cleanup"
DEV_CRON_WATCHDOG="*/5 * * * * $DEV_HOME/.local/bin/tmux-watchdog"
DEV_CRON_BACKUP="30 5 * * * flock -n /tmp/vcc-backup.lock $DEV_HOME/.local/bin/backup"
set +e
sudo -H -u "$DEV_USER" bash -c "
    (crontab -l 2>/dev/null | grep -v 'update-claude' | grep -v 'sync-dotfiles' | grep -v 'logrotate' | grep -v 'health-check' | grep -v 'vcc-update' | grep -v 'disk-cleanup' | grep -v 'tmux-watchdog' | grep -v 'backup' | grep -v '^SHELL=' | grep -v '^HOME='
     echo \"SHELL=/bin/bash\"
     echo \"HOME=$DEV_HOME\"
     echo \"$DEV_CRON_CLAUDE\"
     echo \"$DEV_CRON_DOTFILES\"
     echo \"$DEV_CRON_LOGROTATE\"
     echo \"$DEV_CRON_HEALTH\"
     echo \"$DEV_CRON_VCCUPDATE\"
     echo \"$DEV_CRON_CLEANUP\"
     echo \"$DEV_CRON_WATCHDOG\"
     echo \"$DEV_CRON_BACKUP\"
    ) | crontab -
"
set -e

# Step 11: SSH hardening (last step)
step "Hardening SSH..."

# Pre-flight: verify dev user has valid SSH key
if ! ssh-keygen -l -f "$DEV_HOME/.ssh/authorized_keys" &>/dev/null; then
    echo "FATAL: dev user has no valid SSH key. Aborting SSH hardening." >&2
    echo "The VPS is usable but SSH is NOT hardened. Fix authorized_keys and re-run." >&2
    exit 1
fi

# Safety: install the hardened config but schedule a rollback in case of lockout.
# A cron job will revert the config in 5 minutes unless cancelled.
# The completion message tells the operator to cancel it after verifying SSH access.
# Clear any stale rollback jobs from prior bootstrap runs (prevents double-revert).
if command -v atq &>/dev/null; then
    atq 2>/dev/null | awk '{print $1}' | while read -r job; do
        at -c "$job" 2>/dev/null | grep -q "sshd_config.d/vcc.conf" && atrm "$job" 2>/dev/null
    done
fi
cp "$VCCDIR/config/sshd_config" /etc/ssh/sshd_config.d/vcc.conf
echo "rm -f /etc/ssh/sshd_config.d/vcc.conf && systemctl restart ssh" | at now + 5 minutes 2>/dev/null || \
    echo "WARNING: 'at' not available. No automatic rollback. Verify SSH access immediately."
systemctl restart ssh

# Step 12: Health check
step "Running health check..."
sudo -H -u "$DEV_USER" bash -c "
    export XDG_RUNTIME_DIR=/run/user/$DEV_UID
    $DEV_HOME/.local/bin/health-check
" || true

echo ""
echo "========================================="
echo "VirtualCC Bootstrap Complete!"
echo "========================================="
echo ""
VPS_IP=$(hostname -I | awk '{print $1}')
echo "Dev user password: $DEV_PASSWORD"
echo "  (Also saved to /root/.vcc-dev-password)"
echo ""
echo "--- SSH Hardening (5-minute safety rollback) ---"
echo "  1. Open a NEW terminal and test: ssh dev@$VPS_IP"
echo "  2. If it works, cancel the rollback:  sudo atrm \$(atq | awk '{print \$1}')"
echo "  3. If you can't SSH in, wait 5 minutes — it auto-reverts."
echo ""
echo "--- Next Steps ---"
echo "  1. You'll auto-attach to tmux session 'vcc' with 4 panes"
echo "  2. Run 'claude' to authenticate Claude Code (or use 'ccd' alias)"
echo "  3. Run 'env-edit' to set API keys (GITHUB_TOKEN, BRAVE_API_KEY)"
echo "  4. Use 'clone <repo>' to clone projects into ~/projects/"
echo ""
echo "--- Add to ~/.ssh/config on your local machine ---"
echo "Host vcc"
echo "    HostName $VPS_IP"
echo "    User dev"
echo "    ServerAliveInterval 15"
echo "    ServerAliveCountMax 2"
echo "    IdentityFile ~/.ssh/id_ed25519"
echo ""
echo "--- Mobile access (mosh — survives network drops) ---"
echo "  mosh dev@$VPS_IP"
echo "  Auto-zooms to single pane. Use 'p' to list panes, 'p 0' to switch."
echo "  Install mosh: brew install mosh (macOS) | Blink Shell (iOS) | Termux (Android)"
echo ""
echo "--- Port forwarding (for web dev) ---"
echo "  ssh -L 3000:localhost:3000 vcc"
echo ""
echo "--- Available commands ---"
echo "  cc/ccd/ccr/ccrd  Claude Code aliases (with/without permissions skip)"
echo "  status            Run health check"
echo "  logs              View cron job logs"
echo "  p / p N           List panes / switch to pane N"
echo "  d                 Detach from tmux (safe disconnect)"
echo "  bye               Kill session and disconnect (with confirmation)"
echo "  mobile / desktop  Toggle single-pane / 2x2 grid mode"
echo "  clone <repo>      Clone into ~/projects/"
echo "  env-edit          Edit ~/.env"
echo "========================================="
