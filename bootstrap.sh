#!/bin/bash
# VirtualCC Bootstrap Script
# Provisions a blank Ubuntu 24.04 VPS into a persistent Claude Code environment.
#
# Usage:
#   ssh root@<vps-ip> 'curl -fsSL https://raw.githubusercontent.com/seanpatrickmay/virtualCC/main/bootstrap.sh -o /tmp/bootstrap.sh'
#   ssh root@<vps-ip> 'bash /tmp/bootstrap.sh'
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

echo "========================================="
echo "VirtualCC Bootstrap — Phase 1: System Setup"
echo "========================================="

# Step 1: System packages
echo "[1/11] Installing system packages..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl build-essential zsh tmux unzip python3 openssl ufw fail2ban at

# Ensure atd is running (needed for SSH hardening safety rollback)
systemctl enable atd
systemctl start atd

# Step 2: Firewall
echo "[2/11] Configuring firewall..."
ufw allow ssh
ufw --force enable

# Step 3: Create dev user
echo "[3/11] Creating dev user..."
if ! id "$DEV_USER" &>/dev/null; then
    useradd -m -s /usr/bin/zsh "$DEV_USER"
    usermod -aG sudo "$DEV_USER"
    # Set a random password (user won't use it — SSH key only)
    echo "$DEV_USER:$(openssl rand -base64 32)" | chpasswd
fi

# Copy SSH keys from root to dev
echo "[3b/11] Copying SSH keys to dev user..."
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
echo "[4/11] Installing nvm and Node.js..."
sudo -H -u "$DEV_USER" bash -c '
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh"
    nvm install --lts
'

# Step 5: Claude Code
echo "[5/11] Installing Claude Code..."
sudo -H -u "$DEV_USER" bash -c '
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh"
    npm install -g @anthropic-ai/claude-code
'

# Step 6: Oh My Zsh + Powerlevel10k
echo "[6/11] Installing Oh My Zsh and Powerlevel10k..."
# Download installer first, then run as dev user to avoid $() expanding as root
curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o /tmp/install-omz.sh
sudo -H -u "$DEV_USER" RUNZSH=no CHSH=no bash /tmp/install-omz.sh || true
rm -f /tmp/install-omz.sh
sudo -H -u "$DEV_USER" bash -c '
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
        "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
' 2>/dev/null || true

# Step 7: Dotfiles
echo "[7/11] Installing dotfiles..."
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

# Note: .zshrc.local sourcing is handled by the dotfiles repo.
# The line `[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local` must already
# exist in the dotfiles .zshrc. This is set up in Task 0 (pre-requisite).
# We do NOT modify ~/dotfiles/.zshrc during bootstrap — that would dirty
# the repo and cause git pull --ff-only to fail on the next sync.

# Step 8: tmux systemd service
echo "[8/11] Setting up tmux auto-start service..."
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

echo "[8/11] Waiting for systemd user bus socket..."
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
    echo "[8/11] tmux service started."
fi

# Step 9: Install zshrc.local
echo "[9/11] Installing zshrc.local (tmux auto-attach)..."
sudo -H -u "$DEV_USER" bash -c "cp '$VCCDIR/config/zshrc.local' ~/.zshrc.local"

echo "========================================="
echo "VirtualCC Bootstrap — Phase 3: Finalization"
echo "========================================="

# Step 10: Cron jobs
echo "[10/11] Installing cron jobs..."

# Create log directory
sudo -H -u "$DEV_USER" bash -c "mkdir -p ~/.local/log/cron"

# Install cron wrapper scripts
sudo -H -u "$DEV_USER" bash -c "
    cp '$VCCDIR/config/cron/update-claude' ~/.local/bin/update-claude
    cp '$VCCDIR/config/cron/sync-dotfiles' ~/.local/bin/sync-dotfiles
    chmod +x ~/.local/bin/update-claude ~/.local/bin/sync-dotfiles
"

# Root crontab: weekly system update (install to /usr/local/sbin for stable path)
cp "$VCCDIR/config/cron/update-system" /usr/local/sbin/vcc-update-system
chmod +x /usr/local/sbin/vcc-update-system
SYSTEM_CRON="0 3 * * 0 /usr/local/sbin/vcc-update-system"
(crontab -l 2>/dev/null | grep -v "update-system"; echo "$SYSTEM_CRON") | crontab -

# Dev user crontab
# Note: all variables are expanded in the root shell (double-quoted heredoc).
# The crontab receives the resolved paths, not variable references.
DEV_CRON_CLAUDE="30 3 * * 0 $DEV_HOME/.local/bin/update-claude"
DEV_CRON_DOTFILES="0 4 * * * $DEV_HOME/.local/bin/sync-dotfiles"
sudo -H -u "$DEV_USER" bash -c "
    (crontab -l 2>/dev/null | grep -v 'update-claude' | grep -v 'sync-dotfiles' | grep -v '^SHELL=' | grep -v '^HOME='
     echo \"SHELL=/bin/bash\"
     echo \"HOME=$DEV_HOME\"
     echo \"$DEV_CRON_CLAUDE\"
     echo \"$DEV_CRON_DOTFILES\"
    ) | crontab -
"

# Step 11: SSH hardening (last step)
echo "[11/11] Hardening SSH..."

# Pre-flight: verify dev user has valid SSH key
if ! ssh-keygen -l -f "$DEV_HOME/.ssh/authorized_keys" &>/dev/null; then
    echo "FATAL: dev user has no valid SSH key. Aborting SSH hardening." >&2
    echo "The VPS is usable but SSH is NOT hardened. Fix authorized_keys and re-run." >&2
    exit 1
fi

# Safety: install the hardened config but schedule a rollback in case of lockout.
# A cron job will revert the config in 5 minutes unless cancelled.
# The completion message tells the operator to cancel it after verifying SSH access.
cp "$VCCDIR/config/sshd_config" /etc/ssh/sshd_config.d/vcc.conf
echo "rm -f /etc/ssh/sshd_config.d/vcc.conf && systemctl restart sshd" | at now + 5 minutes 2>/dev/null || \
    echo "WARNING: 'at' not available. No automatic rollback. Verify SSH access immediately."
systemctl restart sshd

echo ""
echo "========================================="
echo "VirtualCC Bootstrap Complete!"
echo "========================================="
echo ""
echo "IMPORTANT: SSH hardening has a 5-minute safety rollback."
echo "  1. Open a NEW terminal and test: ssh dev@$(hostname -I | awk '{print $1}')"
echo "  2. If it works, cancel the rollback:  sudo atrm \$(atq | awk '{print \$1}')"
echo "  3. You'll auto-attach to tmux session 'vcc' with 4 windows"
echo "  4. Run 'claude' to authenticate Claude Code"
echo ""
echo "If you can't SSH in, wait 5 minutes — the config will auto-revert."
echo "========================================="
