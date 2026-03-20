# VirtualCC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a bootstrap script and supporting config files that provision a blank Ubuntu 24.04 VPS into a persistent Claude Code development environment with tmux, dotfiles, and automated maintenance.

**Architecture:** A single `bootstrap.sh` orchestrates all provisioning in three phases: system setup (as root), user environment (as `dev`), and finalization (as root). Config files are stored in this repo under `config/` and copied to their target paths during bootstrap. All scripts are validated with shellcheck.

**Tech Stack:** Bash, systemd, tmux, ufw, cron, nvm, zsh

**Spec:** `docs/superpowers/specs/2026-03-20-virtualcc-design.md`

---

## File Structure

```
virtualCC/
├── bootstrap.sh                    # Main provisioning script (runs as root)
├── config/
│   ├── tmux-session.sh             # Idempotent tmux "vcc" session with 4 windows
│   ├── tmux-vcc.service            # systemd user service unit
│   ├── zshrc.local                 # Auto-attach + dotfiles sync warning
│   ├── sshd_config                 # Hardened SSH config
│   └── cron/
│       ├── update-system           # Weekly apt upgrade wrapper
│       ├── update-claude           # Weekly Claude Code update (sources nvm)
│       └── sync-dotfiles           # Daily dotfiles pull with sentinel
└── tests/
    └── shellcheck.sh               # Runs shellcheck on all scripts
```

---

### Task 0: Add .zshrc.local sourcing to dotfiles repo

**Context:** The bootstrap script must NOT modify `~/dotfiles/.zshrc` on the VPS — that would dirty the repo and break `git pull --ff-only`. Instead, we add the source line to the dotfiles repo now, before bootstrap is ever run.

**Files:**
- Modify: `seanpatrickmay/dotfiles` repo — `.zshrc`

- [ ] **Step 1: Clone dotfiles repo to /tmp, append source line, push**

```bash
cd /tmp && rm -rf dotfiles-prep && git clone https://github.com/seanpatrickmay/dotfiles.git dotfiles-prep
cd /tmp/dotfiles-prep
# Only add if not already present
if ! grep -q "zshrc.local" .zshrc; then
    echo '' >> .zshrc
    echo '# Source local machine-specific overrides (not tracked in this repo)' >> .zshrc
    echo '[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local' >> .zshrc
    git add .zshrc
    git commit -m "Add .zshrc.local sourcing for machine-specific overrides"
    git push origin main
fi
rm -rf /tmp/dotfiles-prep
```

- [ ] **Step 2: Verify the line exists on GitHub**

Run: `gh api repos/seanpatrickmay/dotfiles/contents/.zshrc --jq '.content' | base64 -d | tail -3`
Expected: Last lines include `[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local`

---

### Task 1: tmux-session.sh

**Files:**
- Create: `config/tmux-session.sh`

- [ ] **Step 1: Write tmux-session.sh**

```bash
#!/bin/bash
# Idempotent tmux session creation for VCC.
# Creates session "vcc" with 4 named windows if they don't exist.
# Called by systemd user service and .zshrc.local fallback.

set -euo pipefail

SESSION="vcc"

# Create session if it doesn't exist
tmux has-session -t "$SESSION" 2>/dev/null || \
    tmux new-session -d -s "$SESSION" -n w1

# Create additional windows only if they don't already exist
for win in w2 w3 w4; do
    tmux list-windows -t "$SESSION" -F '#W' | grep -q "^${win}$" || \
        tmux new-window -t "$SESSION" -n "$win"
done
```

- [ ] **Step 2: Make executable and verify syntax**

Run: `chmod +x config/tmux-session.sh && bash -n config/tmux-session.sh`
Expected: No output (valid syntax)

- [ ] **Step 3: Commit**

```bash
git add config/tmux-session.sh
git commit -m "feat: add idempotent tmux session startup script"
```

---

### Task 2: tmux-vcc.service

**Files:**
- Create: `config/tmux-vcc.service`

- [ ] **Step 1: Write systemd unit file**

```ini
[Unit]
Description=VCC tmux session
After=default.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=PATH=/usr/bin:/bin:/usr/local/bin
ExecStart=/home/dev/.local/bin/tmux-session.sh
ExecStop=/usr/bin/tmux kill-session -t vcc

[Install]
WantedBy=default.target
```

- [ ] **Step 2: Validate unit file syntax**

Run: `grep -c "ExecStart=" config/tmux-vcc.service && grep -c "WantedBy=" config/tmux-vcc.service && grep -c "Type=oneshot" config/tmux-vcc.service`
Expected: `1`, `1`, `1` (all critical directives present exactly once)

- [ ] **Step 3: Commit**

```bash
git add config/tmux-vcc.service
git commit -m "feat: add systemd user service for tmux auto-start"
```

---

### Task 3: zshrc.local

**Files:**
- Create: `config/zshrc.local`

- [ ] **Step 1: Write auto-attach snippet with dotfiles sync warning**

```bash
# VCC: Auto-attach to tmux on interactive SSH login.
# This file is installed to ~/.zshrc.local by bootstrap.sh.
# It is NOT part of the dotfiles repo — local-only.

# Warn if dotfiles sync has failed
if [[ -f ~/.local/log/cron/dotfiles-sync-failed ]]; then
    echo "\033[33m⚠ Dotfiles sync has failed. Run 'cd ~/dotfiles && git pull' to investigate.\033[0m"
fi

# Auto-attach to tmux session "vcc" for interactive SSH sessions only.
# Guards: skip if already in tmux, not an SSH session, or non-interactive shell.
# This prevents breaking SCP, SFTP, rsync, and "ssh host command" invocations.
if [[ -z "$TMUX" && -n "$SSH_CONNECTION" && $- == *i* ]]; then
    tmux attach-session -t vcc 2>/dev/null || \
        { /home/dev/.local/bin/tmux-session.sh && tmux attach-session -t vcc; }
fi
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n config/zshrc.local`
Expected: No output (valid syntax)

- [ ] **Step 3: Commit**

```bash
git add config/zshrc.local
git commit -m "feat: add zshrc.local with tmux auto-attach and sync warning"
```

---

### Task 4: sshd_config

**Files:**
- Create: `config/sshd_config`

- [ ] **Step 1: Write hardened sshd config**

```
# VCC hardened SSH config.
# Installed by bootstrap.sh to /etc/ssh/sshd_config.d/vcc.conf
# Uses the sshd_config.d drop-in directory (Ubuntu 24.04 default).

PasswordAuthentication no
PermitRootLogin no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
```

- [ ] **Step 2: Verify syntax**

Run: `grep -c "PasswordAuthentication no" config/sshd_config && grep -c "PermitRootLogin no" config/sshd_config`
Expected: `1` and `1` (both directives present exactly once)

- [ ] **Step 3: Commit**

```bash
git add config/sshd_config
git commit -m "feat: add hardened sshd config (key-only, no root login)"
```

---

### Task 5: Cron Scripts

**Files:**
- Create: `config/cron/update-system`
- Create: `config/cron/update-claude`
- Create: `config/cron/sync-dotfiles`

- [ ] **Step 1: Write update-system**

```bash
#!/bin/bash
# Weekly system update. Runs as root cron (Sunday 3am).
# Uses non-interactive mode to prevent config file prompts.

set -euo pipefail

LOG_DIR="/home/dev/.local/log/cron"
mkdir -p "$LOG_DIR"

{
    echo "=== System update: $(date) ==="
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    echo "=== Done: $(date) ==="
} >> "$LOG_DIR/update-system.log" 2>&1
```

- [ ] **Step 2: Write update-claude**

```bash
#!/bin/bash
# Weekly Claude Code update. Runs as dev cron (Sunday 3:30am).
# Must source nvm explicitly — cron has minimal environment.
# Note: nvm.sh is not compatible with set -e (it exits non-zero internally),
# so we disable it for the source and re-enable after.

LOG_DIR="$HOME/.local/log/cron"
mkdir -p "$LOG_DIR"

{
    echo "=== Claude Code update: $(date) ==="
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    set +e
    source "$NVM_DIR/nvm.sh"
    set -e
    npm update -g @anthropic-ai/claude-code
    echo "=== Done: $(date) ==="
} >> "$LOG_DIR/update-claude.log" 2>&1
```

- [ ] **Step 3: Write sync-dotfiles**

```bash
#!/bin/bash
# Daily dotfiles sync. Runs as dev cron (4am).
# Uses --ff-only to fail cleanly on divergence.
# Writes sentinel file on failure for login warning.
# Note: does NOT use set -e — we handle errors explicitly
# so the sentinel file is always written on failure.

LOG_DIR="$HOME/.local/log/cron"
SENTINEL="$LOG_DIR/dotfiles-sync-failed"
mkdir -p "$LOG_DIR"

{
    echo "=== Dotfiles sync: $(date) ==="
    if ! cd "$HOME/dotfiles" 2>/dev/null; then
        touch "$SENTINEL"
        echo "FAILED: ~/dotfiles directory does not exist."
        echo "=== Done: $(date) ==="
        exit 1
    fi
    if git pull --ff-only; then
        # Clear sentinel on success
        rm -f "$SENTINEL"
        echo "Sync OK"
    else
        touch "$SENTINEL"
        echo "FAILED: git pull --ff-only failed. Manual intervention needed."
    fi
    echo "=== Done: $(date) ==="
} >> "$LOG_DIR/sync-dotfiles.log" 2>&1
```

- [ ] **Step 4: Make all executable and verify syntax**

Run: `chmod +x config/cron/update-system config/cron/update-claude config/cron/sync-dotfiles && bash -n config/cron/update-system && bash -n config/cron/update-claude && bash -n config/cron/sync-dotfiles && echo "All valid"`
Expected: `All valid`

- [ ] **Step 5: Commit**

```bash
git add config/cron/
git commit -m "feat: add cron scripts for system updates, claude updates, and dotfiles sync"
```

---

### Task 6: Shellcheck Validation

**Files:**
- Create: `tests/shellcheck.sh`

- [ ] **Step 1: Write shellcheck runner**

```bash
#!/bin/bash
# Runs shellcheck on all bash scripts in the repo.
# Exit code 0 if all pass, non-zero if any fail.

set -euo pipefail

SCRIPTS=(
    "bootstrap.sh"
    "config/tmux-session.sh"
    "config/cron/update-system"
    "config/cron/update-claude"
    "config/cron/sync-dotfiles"
)

# Skip scripts that don't exist yet (allows running before all tasks complete)
SCRIPTS_FILTERED=()
for s in "${SCRIPTS[@]}"; do
    if [ -f "$s" ]; then
        SCRIPTS_FILTERED+=("$s")
    fi
done

if [ ${#SCRIPTS_FILTERED[@]} -eq 0 ]; then
    echo "No scripts found yet. Skipping."
    exit 0
fi
SCRIPTS=("${SCRIPTS_FILTERED[@]}")

FAILED=0
for script in "${SCRIPTS[@]}"; do
    echo "Checking $script..."
    if shellcheck -x "$script"; then
        echo "  ✓ OK"
    else
        echo "  ✗ FAIL"
        FAILED=1
    fi
done

if [ "$FAILED" -eq 0 ]; then
    echo "All scripts passed shellcheck."
else
    echo "Some scripts failed shellcheck."
    exit 1
fi
```

Note: `config/zshrc.local` uses zsh syntax (`[[ $- == *i* ]]`) and is not checked with shellcheck (which targets bash/sh). `config/sshd_config` and `config/tmux-vcc.service` are not shell scripts.

- [ ] **Step 2: Make executable**

Run: `chmod +x tests/shellcheck.sh`

- [ ] **Step 3: Install shellcheck if needed and run**

Run: `which shellcheck || brew install shellcheck && cd "/Users/seanmay/Desktop/Current Projects/virtualCC" && bash tests/shellcheck.sh`
Expected: All scripts pass. Fix any issues before proceeding.

- [ ] **Step 4: Commit**

```bash
git add tests/shellcheck.sh
git commit -m "feat: add shellcheck validation for all bash scripts"
```

---

### Task 7: bootstrap.sh — Phase 1 (System Setup)

**Files:**
- Create: `bootstrap.sh`

- [ ] **Step 1: Write bootstrap.sh header and Phase 1**

```bash
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
    git curl build-essential zsh tmux unzip python3 ufw fail2ban at

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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n bootstrap.sh`
Expected: No output (valid syntax)

- [ ] **Step 3: Commit**

```bash
git add bootstrap.sh
git commit -m "feat: bootstrap.sh Phase 1 — system packages, firewall, dev user"
```

---

### Task 8: bootstrap.sh — Phase 2 (User Environment)

**Files:**
- Modify: `bootstrap.sh`

- [ ] **Step 1: Append Phase 2 to bootstrap.sh**

Append the following after the Phase 1 code:

```bash
echo "========================================="
echo "VirtualCC Bootstrap — Phase 2: User Environment"
echo "========================================="

# Clone this repo for config files
echo "[*] Cloning virtualCC repo for config files..."
VCCDIR="$DEV_HOME/.local/share/virtualCC"
sudo -u "$DEV_USER" bash -c "mkdir -p '$DEV_HOME/.local/share' && git clone '$REPO_URL' '$VCCDIR'" 2>/dev/null || \
    sudo -u "$DEV_USER" bash -c "cd '$VCCDIR' && git pull"

# Step 4: Node.js via nvm
echo "[4/11] Installing nvm and Node.js..."
sudo -u "$DEV_USER" bash -c '
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
    export NVM_DIR="$HOME/.nvm"
    source "$NVM_DIR/nvm.sh"
    nvm install --lts
'

# Step 5: Claude Code
echo "[5/11] Installing Claude Code..."
sudo -u "$DEV_USER" bash -c '
    export NVM_DIR="$HOME/.nvm"
    source "$NVM_DIR/nvm.sh"
    npm install -g @anthropic-ai/claude-code
'

# Step 6: Oh My Zsh + Powerlevel10k
echo "[6/11] Installing Oh My Zsh and Powerlevel10k..."
sudo -u "$DEV_USER" bash -c '
    RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
'
sudo -u "$DEV_USER" bash -c '
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
        "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
' 2>/dev/null || true

# Step 7: Dotfiles
echo "[7/11] Installing dotfiles..."
sudo -u "$DEV_USER" bash -c "git clone '$DOTFILES_URL' '$DEV_HOME/dotfiles'" 2>/dev/null || \
    sudo -u "$DEV_USER" bash -c "cd '$DEV_HOME/dotfiles' && git pull"

# Symlink dotfiles (force overwrite oh-my-zsh's .zshrc)
sudo -u "$DEV_USER" bash -c '
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
sudo -u "$DEV_USER" bash -c "
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
for i in $(seq 1 30); do
    [ -S "/run/user/$DEV_UID/bus" ] && break
    sleep 1
done

if [ ! -S "/run/user/$DEV_UID/bus" ]; then
    echo "WARNING: User bus socket not found after 30s. tmux service may need manual start."
else
    sudo -u "$DEV_USER" bash -c "
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
sudo -u "$DEV_USER" bash -c "cp '$VCCDIR/config/zshrc.local' ~/.zshrc.local"
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n bootstrap.sh`
Expected: No output (valid syntax)

- [ ] **Step 3: Commit**

```bash
git add bootstrap.sh
git commit -m "feat: bootstrap.sh Phase 2 — nvm, claude code, oh-my-zsh, dotfiles, tmux service"
```

---

### Task 9: bootstrap.sh — Phase 3 (Finalization)

**Files:**
- Modify: `bootstrap.sh`

- [ ] **Step 1: Append Phase 3 to bootstrap.sh**

Append the following after the Phase 2 code:

```bash
echo "========================================="
echo "VirtualCC Bootstrap — Phase 3: Finalization"
echo "========================================="

# Step 10: Cron jobs
echo "[10/11] Installing cron jobs..."

# Create log directory
sudo -u "$DEV_USER" bash -c "mkdir -p ~/.local/log/cron"

# Install cron wrapper scripts
sudo -u "$DEV_USER" bash -c "
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
sudo -u "$DEV_USER" bash -c "
    (crontab -l 2>/dev/null | grep -v 'update-claude' | grep -v 'sync-dotfiles'
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
echo "$(date -d '+5 minutes' '+%H %M') * * * rm -f /etc/ssh/sshd_config.d/vcc.conf && systemctl restart sshd" | at now + 5 minutes 2>/dev/null || \
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
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n bootstrap.sh`
Expected: No output (valid syntax)

- [ ] **Step 3: Run shellcheck on the complete bootstrap.sh**

Run: `bash tests/shellcheck.sh`
Expected: All scripts pass (bootstrap.sh is already in the shellcheck array). Fix any issues.

- [ ] **Step 4: Commit**

```bash
git add bootstrap.sh
git commit -m "feat: bootstrap.sh Phase 3 — cron jobs, SSH hardening, completion message"
```

---

### Task 10: Final Validation and Push

**Files:**
- All files in repo

- [ ] **Step 1: Run full shellcheck suite**

Run: `bash tests/shellcheck.sh`
Expected: All scripts pass.

- [ ] **Step 2: Verify repo structure matches spec**

Run: `find . -not -path './.git/*' -not -path './.git' -not -name '.DS_Store' | sort`

Expected structure:
```
.
./bootstrap.sh
./config
./config/cron
./config/cron/sync-dotfiles
./config/cron/update-claude
./config/cron/update-system
./config/sshd_config
./config/tmux-session.sh
./config/tmux-vcc.service
./config/zshrc.local
./docs
./docs/superpowers
./docs/superpowers/plans
./docs/superpowers/plans/2026-03-20-virtualcc-implementation.md
./docs/superpowers/specs
./docs/superpowers/specs/2026-03-20-virtualcc-design.md
./tests
./tests/shellcheck.sh
```

- [ ] **Step 3: Push to GitHub**

```bash
git push -u origin main
```
