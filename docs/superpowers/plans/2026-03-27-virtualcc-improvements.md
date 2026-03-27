# VirtualCC Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix critical bugs, harden reconnection, improve DX, reduce maintenance burden, and add backup/alerting features to virtualCC.

**Architecture:** All changes are to bash scripts and config files in the existing project structure. A new `config/manifest.txt` centralizes file installation mappings to DRY up bootstrap.sh, vcc-update, Dockerfile.test, and validate-configs.sh. New shell functions go in `config/zshrc.local`. Reconnection fixes go in `config/zprofile.local` and `config/tmux-session.sh`.

**Tech Stack:** Bash, tmux, jq, zsh, systemd, cron, Docker (testing)

---

### Task 1: Install jq and add manifest infrastructure

**Files:**
- Create: `config/manifest.txt`
- Modify: `bootstrap.sh:42-43` (add jq to apt-get install)
- Modify: `Dockerfile.test:5-6` (add jq to apt-get install)

- [ ] **Step 1: Add jq to bootstrap.sh apt-get install list**

In `bootstrap.sh` line 43, add `jq` to the package list:
```bash
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git curl build-essential zsh tmux unzip python3 openssl ufw fail2ban at logrotate mosh jq
```
(jq is already at end of line — verify it's there. If not, add it.)

- [ ] **Step 2: Add jq to Dockerfile.test**

In `Dockerfile.test` line 6, add `jq`:
```bash
RUN apt-get update && apt-get install -y \
    git curl zsh fuse3 libfuse2t64 python3 jq
```

- [ ] **Step 3: Create config/manifest.txt**

```
# VCC File Manifest
# Format: source_path  dest_path  mode
# Used by bootstrap.sh, vcc-update, validate-configs.sh, and Dockerfile.test
# dest_path uses ~ for $HOME expansion
#
# Scripts (executable)
config/cron/update-claude         ~/.local/bin/update-claude         +x
config/cron/sync-dotfiles         ~/.local/bin/sync-dotfiles         +x
config/cron/vcc-update            ~/.local/bin/vcc-update            +x
config/cron/tmux-watchdog         ~/.local/bin/tmux-watchdog         +x
config/cron/disk-cleanup          ~/.local/bin/disk-cleanup          +x
config/health-check.sh            ~/.local/bin/health-check          +x
config/tmux-session.sh            ~/.local/bin/tmux-session.sh       +x
#
# Shell configs (not executable)
config/zshrc.local                ~/.zshrc.local                     644
config/zprofile.local             ~/.zprofile.local                  644
config/logrotate.conf             ~/.config/logrotate.conf           644
#
# Claude configs (merge-mode JSON or bootstrap-only)
# These are handled specially by bootstrap.sh and vcc-update (jq merge for JSON)
config/claude/settings.json       ~/.claude/settings.json            json-merge
config/claude/mcp_config.json     ~/.claude/mcp_config.json          json-merge
config/claude/CLAUDE.md           ~/.claude/CLAUDE.md                bootstrap-only
config/claude/keybindings.json    ~/.claude/keybindings.json         bootstrap-only
```

- [ ] **Step 4: Run shellcheck on bootstrap.sh**

Run: `cd /Users/seanmay/Desktop/Current\ Projects/virtualCC && shellcheck -x bootstrap.sh`
Expected: PASS (no new warnings from jq addition)

- [ ] **Step 5: Commit**

```bash
git add config/manifest.txt bootstrap.sh Dockerfile.test
git commit -m "Add jq dependency and file manifest for config installation"
```

---

### Task 2: Fix vcc-update to use manifest and merge JSON configs

**Files:**
- Modify: `config/cron/vcc-update`

- [ ] **Step 1: Rewrite vcc-update to read manifest and merge JSON**

Replace the hardcoded file copy section (lines 30-57) with manifest-driven installation:

```bash
#!/bin/bash
# Self-update: pull latest virtualCC repo and re-apply configs.
# Runs as dev cron (daily). Safe to run manually too.
# Idempotent — only copies files if repo pull succeeds.

LOG_DIR="$HOME/.local/log/cron"
SENTINEL="$LOG_DIR/vcc-update-failed"
mkdir -p "$LOG_DIR"

VCCDIR="$HOME/.local/share/virtualCC"

{
    echo "=== VCC self-update: $(date) ==="

    if [ ! -d "$VCCDIR/.git" ]; then
        echo "SKIP: virtualCC repo not found at $VCCDIR"
        echo "=== Done: $(date) ==="
        exit 0
    fi

    cd "$VCCDIR" || exit 1

    # Pull latest (ff-only to avoid conflicts)
    if ! git pull --ff-only; then
        echo "WARNING: git pull --ff-only failed. Manual intervention needed."
        touch "$SENTINEL"
        echo "=== Done: $(date) ==="
        exit 1
    fi

    echo "Applying updated configs..."

    # Read manifest and install files
    while IFS=$'\t' read -r src dest mode; do
        # Skip comments and blank lines
        [[ -z "$src" || "$src" == \#* ]] && continue
        # Trim whitespace (manifest may use spaces)
        src=$(echo "$src" | xargs)
        dest=$(echo "$dest" | xargs)
        mode=$(echo "$mode" | xargs)
        # Expand ~ to $HOME
        dest="${dest/#\~/$HOME}"

        if [ ! -f "$VCCDIR/$src" ]; then
            echo "WARNING: $src not found in repo, skipping"
            continue
        fi

        mkdir -p "$(dirname "$dest")"

        case "$mode" in
            json-merge)
                # Merge repo defaults with user's existing config (user wins)
                if [ -f "$dest" ] && command -v jq &>/dev/null; then
                    jq -s '.[0] * .[1]' "$VCCDIR/$src" "$dest" > "$dest.tmp" 2>/dev/null && \
                        mv "$dest.tmp" "$dest" || \
                        cp "$VCCDIR/$src" "$dest"
                else
                    cp "$VCCDIR/$src" "$dest"
                fi
                ;;
            bootstrap-only)
                # Only install if file doesn't exist (never overwrite)
                [ -f "$dest" ] || cp "$VCCDIR/$src" "$dest"
                ;;
            +x)
                cp "$VCCDIR/$src" "$dest.tmp" && mv "$dest.tmp" "$dest"
                chmod +x "$dest"
                ;;
            *)
                cp "$VCCDIR/$src" "$dest.tmp" && mv "$dest.tmp" "$dest"
                ;;
        esac
    done < "$VCCDIR/config/manifest.txt"

    rm -f "$SENTINEL"
    echo "Configs applied."
    echo "=== Done: $(date) ==="
} >> "$LOG_DIR/vcc-update.log" 2>&1
```

- [ ] **Step 2: Run shellcheck**

Run: `shellcheck -x config/cron/vcc-update`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add config/cron/vcc-update
git commit -m "Rewrite vcc-update to use manifest with JSON merge and atomic writes"
```

---

### Task 3: Fix bootstrap.sh config installation to use manifest

**Files:**
- Modify: `bootstrap.sh` (step 5b and step 10 sections)

- [ ] **Step 1: Add a manifest installer function near the top of bootstrap.sh**

After the variable declarations (after line 30), add:

```bash
# Install files from manifest. Usage: install_from_manifest <manifest_path> <home_dir> [mode_filter]
# mode_filter: if set, only install lines matching this mode (e.g., "+x" for executables)
install_from_manifest() {
    local manifest="$1" home="$2" filter="${3:-}"
    while IFS=$'\t' read -r src dest mode; do
        [[ -z "$src" || "$src" == \#* ]] && continue
        src=$(echo "$src" | xargs)
        dest=$(echo "$dest" | xargs)
        mode=$(echo "$mode" | xargs)
        dest="${dest/#\~/$home}"
        [[ -n "$filter" && "$mode" != "$filter" ]] && continue

        local vcc_src="$VCCDIR/$src"
        [ -f "$vcc_src" ] || continue
        mkdir -p "$(dirname "$dest")"

        case "$mode" in
            json-merge)
                if [ -f "$dest" ] && command -v jq &>/dev/null; then
                    jq -s '.[0] * .[1]' "$vcc_src" "$dest" > "$dest.tmp" 2>/dev/null && \
                        mv "$dest.tmp" "$dest" || cp "$vcc_src" "$dest"
                else
                    cp "$vcc_src" "$dest"
                fi
                ;;
            bootstrap-only)
                [ -f "$dest" ] || cp "$vcc_src" "$dest"
                ;;
            +x)
                cp "$vcc_src" "$dest"
                chmod +x "$dest"
                ;;
            *)
                cp "$vcc_src" "$dest"
                ;;
        esac
    done < "$manifest"
}
```

- [ ] **Step 2: Replace step 5b (Claude config) with manifest call**

Replace the step 5b section with:
```bash
# Step 5b: Claude Code config
echo "[5b/12] Installing Claude Code config..."
sudo -H -u "$DEV_USER" bash -c "
    mkdir -p ~/.claude
"
install_from_manifest "$VCCDIR/config/manifest.txt" "$DEV_HOME" "json-merge"
install_from_manifest "$VCCDIR/config/manifest.txt" "$DEV_HOME" "bootstrap-only"
# Install env template if no .env exists yet
[ -f "$DEV_HOME/.env" ] || sudo -H -u "$DEV_USER" cp "$VCCDIR/config/env.template" "$DEV_HOME/.env"
```

- [ ] **Step 3: Replace step 10 script installation with manifest call**

Replace the hardcoded cp commands in step 10 with:
```bash
# Install cron wrapper scripts, health check, and shell configs from manifest
sudo -H -u "$DEV_USER" bash -c "mkdir -p ~/.local/bin ~/.local/log/cron ~/.local/state ~/.config"
install_from_manifest "$VCCDIR/config/manifest.txt" "$DEV_HOME" "+x"
install_from_manifest "$VCCDIR/config/manifest.txt" "$DEV_HOME" "644"
```

- [ ] **Step 4: Add step counter function**

Replace hardcoded `[N/12]` markers. After variable declarations, add:
```bash
STEP=0
TOTAL=12
step() { STEP=$((STEP + 1)); echo "[$STEP/$TOTAL] $1"; }
```

Then replace all `echo "[1/12] Installing..."` with `step "Installing..."` throughout.

- [ ] **Step 5: Fix dev user creation to work on re-runs**

Move usermod and chpasswd outside the `if ! id` guard:
```bash
# Step 3: Create dev user
step "Creating dev user..."
if ! id "$DEV_USER" &>/dev/null; then
    useradd -m -s /usr/bin/zsh "$DEV_USER"
fi
usermod -aG sudo "$DEV_USER"
chsh -s /usr/bin/zsh "$DEV_USER" 2>/dev/null || true
echo "$DEV_USER:$DEV_PASSWORD" | chpasswd
```

- [ ] **Step 6: Print DEV_PASSWORD in completion message**

In the completion message section, add:
```bash
echo "Dev user password: $DEV_PASSWORD"
echo "  (Also saved to /root/.vcc-dev-password)"
echo ""
```
And save it:
```bash
echo "$DEV_PASSWORD" > /root/.vcc-dev-password
chmod 600 /root/.vcc-dev-password
```

- [ ] **Step 7: Improve completion message with SSH config block and port forwarding**

Replace the existing completion echo block with an expanded version including:
- Full SSH config with keepalive settings
- Mosh client install guidance
- Port forwarding example
- DEV_PASSWORD

- [ ] **Step 8: Run shellcheck**

Run: `shellcheck -x bootstrap.sh`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add bootstrap.sh
git commit -m "Refactor bootstrap.sh: manifest installer, step counter, fix re-run safety"
```

---

### Task 4: Fix update-claude to check for running processes

**Files:**
- Modify: `config/cron/update-claude`

- [ ] **Step 1: Add process check and sentinel file**

```bash
#!/bin/bash
# Weekly Claude Code update. Runs as dev cron (Sunday 3:30am).
# Must source nvm explicitly — cron has minimal environment.
# Skips update if Claude is actively running to prevent mid-session disruption.

LOG_DIR="$HOME/.local/log/cron"
SENTINEL="$LOG_DIR/update-claude-failed"
mkdir -p "$LOG_DIR"

{
    echo "=== Claude Code update: $(date) ==="

    # Don't update while Claude is running
    if pgrep -f "claude" >/dev/null 2>&1; then
        echo "Claude Code is running, skipping update"
        echo "=== Done: $(date) ==="
        exit 0
    fi

    export NVM_DIR="$HOME/.nvm"
    set +e
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh"
    set -e

    if npm update -g @anthropic-ai/claude-code; then
        rm -f "$SENTINEL"
    else
        touch "$SENTINEL"
        echo "WARNING: npm update failed"
    fi

    echo "=== Done: $(date) ==="
} >> "$LOG_DIR/update-claude.log" 2>&1
```

- [ ] **Step 2: Run shellcheck**

Run: `shellcheck -x config/cron/update-claude`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add config/cron/update-claude
git commit -m "Fix update-claude: skip if running, add failure sentinel"
```

---

### Task 5: Fix reconnection robustness in zprofile.local

**Files:**
- Modify: `config/zprofile.local`

- [ ] **Step 1: Rewrite zprofile.local with reconnection fixes**

```bash
# VCC: Auto-attach to tmux BEFORE .zshrc runs.
# Must happen before p10k instant prompt captures the terminal.
#
# Reconnection robustness:
#   - Uses -d flag to detach other clients (fixes stale sessions after SSH drop)
#   - Handles terminal size mismatch (tmux resizes to last-attached client)
#   - Falls back to plain shell if tmux is broken (no exec = no disconnect)
#   - Handles stale tmux server socket
#
# Mobile detection: if terminal is narrow (< 160 cols), auto-zoom
# the current pane so you get a single full-screen view. Desktop
# users keep the 2x2 grid.

if [[ -z "$TMUX" && -n "$SSH_CONNECTION" && -o interactive ]]; then
    _vcc_attach() {
        # If tmux server is dead but socket lingers, clean up
        if ! tmux list-sessions &>/dev/null 2>&1; then
            tmux kill-server 2>/dev/null || true
            sleep 0.3
        fi

        # Ensure session exists
        if ! tmux has-session -t vcc 2>/dev/null; then
            if [[ -x /home/dev/.local/bin/tmux-session.sh ]]; then
                /home/dev/.local/bin/tmux-session.sh
            else
                echo "WARNING: tmux-session.sh not found. Starting plain shell."
                return 1
            fi
        fi

        # Detect narrow terminal (phone/tablet) and auto-zoom
        # 160 cols = threshold where 2x2 grid gives 80+ cols per pane
        local cols
        cols=$(tput cols 2>/dev/null || echo 160)

        # Attach with -d to detach other clients (fixes stale sessions + size mismatch)
        # Fall back to plain shell if attach fails (no exec = safe fallback)
        if [[ "$cols" -lt 160 ]]; then
            tmux attach-session -d -t vcc \; resize-pane -Z && exit
        else
            tmux attach-session -d -t vcc && exit
        fi

        echo "WARNING: Could not attach to tmux session 'vcc'. Starting plain shell."
    }
    _vcc_attach
fi
```

- [ ] **Step 2: Commit**

```bash
git add config/zprofile.local
git commit -m "Fix reconnection: detach stale clients, handle dead server, safe fallback"
```

---

### Task 6: Fix tmux-session.sh with locking and timestamp

**Files:**
- Modify: `config/tmux-session.sh`

- [ ] **Step 1: Add flock and session-created timestamp**

```bash
#!/bin/bash
# Idempotent tmux session creation for VCC.
# Creates session "vcc" with a single window containing a 2x2 pane grid.
# Called by systemd user service, cron watchdog, and zprofile.local fallback.
# Uses flock to prevent race conditions between callers.

set -euo pipefail

SESSION="vcc"
LOCK_FILE="/tmp/vcc-session-create.lock"

# Acquire lock (wait up to 5 seconds)
exec 200>"$LOCK_FILE"
flock -w 5 200 || { echo "Session creation already in progress"; exit 0; }

# Create session if it doesn't exist
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux new-session -d -s "$SESSION"

    # Split into 2x2 grid
    tmux split-window -h -t "$SESSION"
    tmux split-window -v -t "$SESSION:0.0"
    tmux split-window -v -t "$SESSION:0.2"

    # Even out the layout
    tmux select-layout -t "$SESSION" tiled

    # Start in the top-left pane
    tmux select-pane -t "$SESSION:0.0"

    # Record creation time for reboot detection
    mkdir -p "$HOME/.local/state"
    date > "$HOME/.local/state/vcc-session-created"
fi

# Source user customizations if present
if [ -f "$HOME/.config/vcc/tmux-custom.sh" ]; then
    # shellcheck source=/dev/null
    source "$HOME/.config/vcc/tmux-custom.sh"
fi
```

- [ ] **Step 2: Run shellcheck**

Run: `shellcheck -x config/tmux-session.sh`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add config/tmux-session.sh
git commit -m "Add flock, session timestamp, and user hook to tmux-session.sh"
```

---

### Task 7: Rewrite zshrc.local with full DX improvements

**Files:**
- Modify: `config/zshrc.local`

- [ ] **Step 1: Rewrite zshrc.local with all DX improvements**

```bash
# VCC: Local zsh config for the VPS.
# This file is installed to ~/.zshrc.local by bootstrap.sh.
# It is NOT part of the dotfiles repo — local-only.

# Load environment variables (API keys, tokens)
if [[ -f ~/.env ]]; then
    while IFS='=' read -r key value; do
        # Skip comments and blank lines
        [[ -z "$key" || "$key" == \#* ]] && continue
        export "$key=$value"
    done < ~/.env
fi
# gh CLI uses GH_TOKEN (set it from GITHUB_TOKEN if not already set)
[[ -n "${GITHUB_TOKEN:-}" && -z "${GH_TOKEN:-}" ]] && export GH_TOKEN="$GITHUB_TOKEN"

# Load nvm (dotfiles .zshrc overwrites nvm's auto-added lines)
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

# === Claude Code aliases ===
alias cc='claude'
alias ccd='claude --dangerously-skip-permissions'
alias ccr='claude --resume'
alias ccrd='claude --resume --dangerously-skip-permissions'
alias ccp='claude --plan'
alias ccs='claude status'
alias cch='claude --help'

# === Utility aliases ===
alias c='claude'
alias d='tmux detach-client'
alias status='~/.local/bin/health-check'

# === Login status ===
_pane_idx=$(tmux display-message -p '#{pane_index}' 2>/dev/null || echo "?")

_vcc_status() {
    local disk mem warn=""
    disk=$(df / 2>/dev/null | awk 'NR==2 {print $5}')
    mem=$(free -m 2>/dev/null | awk '/Mem:/ {printf "%d/%dMB", $3, $2}')
    panes=$(tmux list-panes -t vcc 2>/dev/null | wc -l | tr -d ' ')

    # Check for warnings
    [[ ! -f ~/.env ]] || ! grep -q 'GITHUB_TOKEN=.' ~/.env 2>/dev/null && warn=" | \033[33m⚠ run: env-edit\033[0m"
    [[ -f ~/.local/log/cron/dotfiles-sync-failed ]] && warn="$warn | \033[33m⚠ dotfiles sync failed\033[0m"
    [[ -f ~/.local/log/cron/vcc-update-failed ]] && warn="$warn | \033[33m⚠ vcc update failed\033[0m"
    [[ -f ~/.local/log/cron/update-claude-failed ]] && warn="$warn | \033[33m⚠ claude update failed\033[0m"

    # Reboot/recovery detection
    local session_age=""
    if [[ -f ~/.local/state/vcc-session-created ]]; then
        local created now diff_min
        created=$(date -r ~/.local/state/vcc-session-created +%s 2>/dev/null || echo 0)
        now=$(date +%s)
        diff_min=$(( (now - created) / 60 ))
        if [[ "$diff_min" -lt 10 ]]; then
            session_age=" | \033[36msession created ${diff_min}m ago\033[0m"
        fi
    fi

    echo -e "\033[90m[vcc] disk:${disk} mem:${mem} panes:${panes}${warn}${session_age}\033[0m"
}

if [[ "$_pane_idx" == "0" ]]; then
    _vcc_status
else
    echo -e "\033[90m[vcc:pane${_pane_idx}]\033[0m"
fi
unset -f _vcc_status
unset _pane_idx

# === Shell functions ===

# Kill tmux session and disconnect (with confirmation)
bye() {
    if [[ -z "${TMUX:-}" ]]; then
        echo "Not in a tmux session."
        return 1
    fi
    echo -n "Kill all panes and disconnect? [y/N] "
    read -r ans
    [[ "$ans" == [yY] ]] && tmux kill-session -t vcc
}

# Quick pane switcher (works in zoomed mode)
# No args: list panes. With arg: switch to that pane.
p() {
    if [[ -z "${1:-}" ]]; then
        tmux list-panes -t vcc -F '  #{pane_index}: #{pane_current_command} (#{pane_current_path})' 2>/dev/null
        return
    fi
    local target="$1"
    if [[ "$(tmux display-message -p '#{window_zoomed_flag}')" == "1" ]]; then
        tmux resize-pane -Z
    fi
    tmux select-pane -t "$target"
    tmux resize-pane -Z
}

# Mobile/desktop mode switching
mobile() {
    if [[ -z "${TMUX:-}" ]]; then echo "Not in tmux."; return 1; fi
    tmux resize-pane -Z 2>/dev/null
}
desktop() {
    if [[ -z "${TMUX:-}" ]]; then echo "Not in tmux."; return 1; fi
    [[ "$(tmux display-message -p '#{window_zoomed_flag}')" == "1" ]] && tmux resize-pane -Z
    tmux select-layout -t vcc tiled
}

# Cron log viewer
logs() {
    local lines="${1:-5}"
    for f in ~/.local/log/cron/*.log; do
        [ -f "$f" ] || continue
        echo "=== $(basename "$f" .log) ==="
        tail -"$lines" "$f"
        echo
    done
}

# Edit environment variables
env-edit() {
    ${EDITOR:-nvim} ~/.env
    echo "Restart your shell or run: source ~/.zshrc.local"
}

# Clone a project into ~/projects/
clone() {
    local repo="$1" dest="${2:-}"
    if [[ -z "${repo:-}" ]]; then
        echo "Usage: clone <repo> [dir]"
        echo "  clone life-dashboard         -> github.com/seanpatrickmay/life-dashboard"
        echo "  clone user/repo              -> github.com/user/repo"
        echo "  clone https://github.com/... -> as-is"
        return 1
    fi
    [[ "$repo" != */* ]] && repo="seanpatrickmay/$repo"
    [[ "$repo" != https://* && "$repo" != git@* ]] && repo="https://github.com/$repo"
    local name="${dest:-$(basename "$repo" .git)}"
    mkdir -p ~/projects
    git clone "$repo" ~/projects/"$name" && cd ~/projects/"$name"
}

# Source user customizations (never managed by vcc-update)
[[ -f ~/.zshrc.user ]] && source ~/.zshrc.user
```

- [ ] **Step 2: Commit**

```bash
git add config/zshrc.local
git commit -m "Rewrite zshrc.local: Claude aliases, DX helpers, sentinel checks, user hooks"
```

---

### Task 8: Fix cron jobs (flock, sentinels, safety)

**Files:**
- Modify: `config/cron/sync-dotfiles` (already has sentinel — no change needed)
- Modify: `config/cron/disk-cleanup`
- Modify: `config/cron/tmux-watchdog`
- Modify: `config/cron/update-system`

- [ ] **Step 1: Fix disk-cleanup (safer /tmp, add -type f, increase to 30 days)**

```bash
#!/bin/bash
# Weekly disk cleanup for long-running VPS.
# Prevents gradual disk fill from caches, logs, and temp files.
# Runs as dev cron (Sundays 2am — before system update at 3am).

LOG_DIR="$HOME/.local/log/cron"
mkdir -p "$LOG_DIR"

{
    echo "=== Disk cleanup: $(date) ==="
    echo "Before: $(df -h / | awk 'NR==2 {print $4}') free"

    # npm cache (can grow to GBs over time)
    if [ -s "$HOME/.nvm/nvm.sh" ]; then
        export NVM_DIR="$HOME/.nvm"
        # shellcheck source=/dev/null
        source "$NVM_DIR/nvm.sh"
        npm cache clean --force 2>/dev/null && echo "Cleaned npm cache"
    fi

    # Old npm tmp files
    rm -rf "$HOME/.npm/_cacache/tmp" 2>/dev/null && echo "Cleaned npm tmp"

    # Old log files beyond what logrotate keeps
    find "$LOG_DIR" -name "*.log.*.gz" -type f -mtime +30 -delete 2>/dev/null && echo "Cleaned old compressed logs"

    # Temp files older than 30 days (safe for long-running Claude sessions)
    find /tmp -user "$(whoami)" -type f -mtime +30 -delete 2>/dev/null && echo "Cleaned old tmp files"

    echo "After: $(df -h / | awk 'NR==2 {print $4}') free"
    echo "=== Done: $(date) ==="
} >> "$LOG_DIR/disk-cleanup.log" 2>&1
```

- [ ] **Step 2: Fix update-system (log ownership)**

```bash
#!/bin/bash
# Weekly system update. Runs as root cron (Sunday 3am).
# Uses non-interactive mode to prevent config file prompts.

set -euo pipefail

# Log to dev's directory but fix ownership after writing
LOG_FILE="/home/dev/.local/log/cron/update-system.log"
mkdir -p "$(dirname "$LOG_FILE")"

{
    echo "=== System update: $(date) ==="
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
    echo "=== Done: $(date) ==="
} >> "$LOG_FILE" 2>&1

# Fix ownership (this script runs as root)
chown dev:dev "$LOG_FILE" 2>/dev/null || true
```

- [ ] **Step 3: Run shellcheck on all modified scripts**

Run: `shellcheck -x config/cron/disk-cleanup config/cron/update-system`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add config/cron/disk-cleanup config/cron/update-system
git commit -m "Fix cron jobs: safer cleanup, fix log ownership"
```

---

### Task 9: Fix health-check.sh (XDG_RUNTIME_DIR, webhook, uptime ping)

**Files:**
- Modify: `config/health-check.sh`

- [ ] **Step 1: Add XDG_RUNTIME_DIR, webhook alerts, and uptime ping**

Add near the top (after `set -uo pipefail`):
```bash
# Ensure systemctl --user works from cron (needs XDG_RUNTIME_DIR)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
```

Add at the very end (before `exit "$STATUS"`):
```bash
# === Optional: Webhook alert on degraded/critical ===
if [[ "$STATUS" -gt 0 && -n "${VCC_ALERT_WEBHOOK:-}" ]]; then
    curl -s -m 5 -H "Content-Type: application/json" \
        -d "{\"content\":\"VCC Health: $LABEL on $(hostname -f 2>/dev/null || hostname) — $(date)\"}" \
        "$VCC_ALERT_WEBHOOK" 2>/dev/null || true
fi

# === Optional: Uptime ping (e.g., healthchecks.io) ===
if [[ -n "${VCC_HEALTHCHECK_PING_URL:-}" ]]; then
    if [[ "$STATUS" -eq 0 ]]; then
        curl -fsS -m 5 --retry 3 "$VCC_HEALTHCHECK_PING_URL" 2>/dev/null || true
    else
        curl -fsS -m 5 --retry 3 "$VCC_HEALTHCHECK_PING_URL/fail" 2>/dev/null || true
    fi
fi
```

- [ ] **Step 2: Run shellcheck**

Run: `shellcheck -x config/health-check.sh`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add config/health-check.sh
git commit -m "Fix health-check: XDG_RUNTIME_DIR, add webhook alerts and uptime ping"
```

---

### Task 10: Add backup cron script

**Files:**
- Create: `config/cron/backup`

- [ ] **Step 1: Create the backup script**

```bash
#!/bin/bash
# Daily backup of non-git state (API keys, Claude auth, gitconfig).
# Keeps 7 days of local backups in ~/.local/backups/.
# Runs as dev cron (daily 5:30am).

LOG_DIR="$HOME/.local/log/cron"
BACKUP_DIR="$HOME/.local/backups"
mkdir -p "$LOG_DIR" "$BACKUP_DIR"

{
    echo "=== Backup: $(date) ==="

    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    BACKUP_FILE="$BACKUP_DIR/vcc-backup-$TIMESTAMP.tar.gz"

    # Collect files to back up (only if they exist)
    FILES_TO_BACKUP=()
    [ -f "$HOME/.env" ] && FILES_TO_BACKUP+=("$HOME/.env")
    [ -f "$HOME/.gitconfig" ] && FILES_TO_BACKUP+=("$HOME/.gitconfig")
    [ -d "$HOME/.claude" ] && FILES_TO_BACKUP+=("$HOME/.claude")

    # Back up uncommitted changes from project repos
    DIFF_DIR=$(mktemp -d)
    if [ -d "$HOME/projects" ]; then
        for repo in "$HOME/projects"/*/; do
            [ -d "$repo/.git" ] || continue
            REPO_NAME=$(basename "$repo")
            DIFF_FILE="$DIFF_DIR/$REPO_NAME.diff"
            if git -C "$repo" diff --quiet && git -C "$repo" diff --cached --quiet; then
                continue  # Clean repo, skip
            fi
            git -C "$repo" diff HEAD > "$DIFF_FILE" 2>/dev/null || true
            [ -s "$DIFF_FILE" ] && FILES_TO_BACKUP+=("$DIFF_FILE")
        done
    fi

    if [ ${#FILES_TO_BACKUP[@]} -eq 0 ]; then
        echo "Nothing to back up."
    else
        tar czf "$BACKUP_FILE" "${FILES_TO_BACKUP[@]}" 2>/dev/null
        echo "Created: $BACKUP_FILE ($(du -h "$BACKUP_FILE" | awk '{print $1}'))"
    fi

    rm -rf "$DIFF_DIR"

    # Rotate: keep only last 7 days
    find "$BACKUP_DIR" -name "vcc-backup-*.tar.gz" -type f -mtime +7 -delete 2>/dev/null
    BACKUP_COUNT=$(find "$BACKUP_DIR" -name "vcc-backup-*.tar.gz" -type f | wc -l | tr -d ' ')
    echo "Backups on disk: $BACKUP_COUNT"

    echo "=== Done: $(date) ==="
} >> "$LOG_DIR/backup.log" 2>&1
```

- [ ] **Step 2: Add backup to manifest.txt**

Add line to `config/manifest.txt`:
```
config/cron/backup                ~/.local/bin/backup               +x
```

- [ ] **Step 3: Add backup cron entry to bootstrap.sh**

Add a new `DEV_CRON_BACKUP` variable and include it in the crontab pipe:
```bash
DEV_CRON_BACKUP="30 5 * * * $DEV_HOME/.local/bin/backup"
```

- [ ] **Step 4: Add shellcheck entry**

Add `"config/cron/backup"` to the `SCRIPTS` array in `tests/shellcheck.sh`.

- [ ] **Step 5: Run shellcheck**

Run: `shellcheck -x config/cron/backup`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add config/cron/backup config/manifest.txt bootstrap.sh tests/shellcheck.sh
git commit -m "Add daily backup cron for env, claude auth, gitconfig, uncommitted diffs"
```

---

### Task 11: Update env.template with new variables

**Files:**
- Modify: `config/env.template`

- [ ] **Step 1: Add new env vars**

```
# VCC Environment Variables
# Copy to ~/.env and fill in your values.
# Sourced automatically by .zshrc.local on every shell login.
#
# Lines starting with # are ignored. Blank lines are ignored.
# Format: KEY=value (no spaces around =, no export needed)

# GitHub Personal Access Token (for MCP github server + gh CLI)
# Create at: https://github.com/settings/tokens
# Needs: repo, read:org scopes
# Also used by gh CLI (auto-exported as GH_TOKEN)
GITHUB_TOKEN=

# Brave Search API Key (for MCP brave-search server)
# Get one at: https://brave.com/search/api/
BRAVE_API_KEY=

# === Optional: Monitoring & Alerts ===

# Webhook URL for health alerts (Discord, Slack, etc.)
# Leave empty to disable. Health check runs every 6 hours.
# Discord: Create webhook in channel settings -> Integrations -> Webhooks
VCC_ALERT_WEBHOOK=

# Uptime ping URL (e.g., healthchecks.io free tier)
# Pings on health check success, /fail on degraded/critical.
# Leave empty to disable.
VCC_HEALTHCHECK_PING_URL=
```

- [ ] **Step 2: Commit**

```bash
git add config/env.template
git commit -m "Add webhook and uptime ping env vars to template"
```

---

### Task 12: Update bootstrap.sh crontab section with flock and new jobs

**Files:**
- Modify: `bootstrap.sh` (crontab section, ~lines 327-351)

- [ ] **Step 1: Add flock to all cron entries and add backup job**

Update the cron variable definitions to wrap in flock:
```bash
DEV_CRON_CLAUDE="30 3 * * 0 flock -n /tmp/vcc-update-claude.lock $DEV_HOME/.local/bin/update-claude"
DEV_CRON_DOTFILES="0 4 * * * flock -n /tmp/vcc-sync-dotfiles.lock $DEV_HOME/.local/bin/sync-dotfiles"
DEV_CRON_LOGROTATE="0 5 * * 0 /usr/sbin/logrotate --state $DEV_HOME/.local/state/logrotate.status $DEV_HOME/.config/logrotate.conf"
DEV_CRON_HEALTH="0 */6 * * * $DEV_HOME/.local/bin/health-check >> $DEV_HOME/.local/log/cron/health-check.log 2>&1"
DEV_CRON_VCCUPDATE="30 4 * * * flock -n /tmp/vcc-update.lock $DEV_HOME/.local/bin/vcc-update"
DEV_CRON_CLEANUP="0 2 * * 0 flock -n /tmp/vcc-disk-cleanup.lock $DEV_HOME/.local/bin/disk-cleanup"
DEV_CRON_WATCHDOG="*/5 * * * * $DEV_HOME/.local/bin/tmux-watchdog"
DEV_CRON_BACKUP="30 5 * * * flock -n /tmp/vcc-backup.lock $DEV_HOME/.local/bin/backup"
```

Add `backup` to the grep -v filter and the echo list in the crontab pipe.

- [ ] **Step 2: Run shellcheck**

Run: `shellcheck -x bootstrap.sh`
Expected: PASS

- [ ] **Step 3: Commit**

```bash
git add bootstrap.sh
git commit -m "Add flock to cron jobs, add backup cron entry"
```

---

### Task 13: Update validate-configs.sh for manifest-based validation

**Files:**
- Modify: `tests/validate-configs.sh`

- [ ] **Step 1: Add manifest-based validation and plugin list check**

Add a new section that reads manifest.txt and verifies all source files exist:
```bash
echo "Manifest file targets exist:"
while IFS=$'\t' read -r src dest mode; do
    [[ -z "$src" || "$src" == \#* ]] && continue
    src=$(echo "$src" | xargs)
    if [ -f "$src" ]; then
        check "$src" 0
    else
        check "$src: MISSING" 1
    fi
done < config/manifest.txt
```

Add nvim plugin list consistency check:
```bash
echo ""
echo "Nvim plugin list consistency (bootstrap vs Dockerfile):"
BOOTSTRAP_PLUGINS=$(grep -o 'clone [a-zA-Z0-9_-]*/[a-zA-Z0-9._-]* ' bootstrap.sh | awk '{print $2}' | sort)
DOCKER_PLUGINS=$(grep -o 'github.com/[a-zA-Z0-9_-]*/[a-zA-Z0-9._-]*' Dockerfile.test | sed 's|github.com/||' | sort)
if [ "$BOOTSTRAP_PLUGINS" = "$DOCKER_PLUGINS" ]; then
    check "Plugin lists match" 0
else
    check "Plugin lists DIFFER" 1
    echo "    bootstrap only: $(comm -23 <(echo "$BOOTSTRAP_PLUGINS") <(echo "$DOCKER_PLUGINS"))"
    echo "    Dockerfile only: $(comm -13 <(echo "$BOOTSTRAP_PLUGINS") <(echo "$DOCKER_PLUGINS"))"
fi
```

- [ ] **Step 2: Run the validation tests**

Run: `bash tests/validate-configs.sh`
Expected: PASS (or known diffs that we fix)

- [ ] **Step 3: Commit**

```bash
git add tests/validate-configs.sh
git commit -m "Add manifest validation and plugin list consistency check to test suite"
```

---

### Task 14: Add GitHub Actions CI

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Create CI workflow**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  lint:
    name: Shellcheck & Config Validation
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install shellcheck
        run: sudo apt-get install -y shellcheck
      - name: Run shellcheck
        run: bash tests/shellcheck.sh
      - name: Run config validation
        run: bash tests/validate-configs.sh

  docker:
    name: Docker Build Test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build test image
        run: docker build -f Dockerfile.test -t vcc-test .
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "Add GitHub Actions CI (shellcheck, config validation, docker build)"
```

---

### Task 15: Update Dockerfile.test for manifest and new files

**Files:**
- Modify: `Dockerfile.test`

- [ ] **Step 1: Update Dockerfile to install new files and verify backup script**

Add backup script to the verification section. Update the RUN verification block to include:
```
test -x ~/.local/bin/backup && echo "✓ backup executable" && \
```

- [ ] **Step 2: Commit**

```bash
git add Dockerfile.test
git commit -m "Update Dockerfile.test for new backup script and jq dependency"
```

---

### Task 16: Run full test suite and fix any issues

**Files:** All modified files

- [ ] **Step 1: Run shellcheck on all scripts**

Run: `bash tests/shellcheck.sh`
Expected: All pass

- [ ] **Step 2: Run config validation**

Run: `bash tests/validate-configs.sh`
Expected: All pass

- [ ] **Step 3: Build Docker test image**

Run: `docker build -f Dockerfile.test -t vcc-test .`
Expected: Build succeeds

- [ ] **Step 4: Fix any failures and commit**

---

### Task 17: Update design spec to match current reality

**Files:**
- Modify: `docs/superpowers/specs/2026-03-20-virtualcc-design.md`

- [ ] **Step 1: Update architecture, file structure, step counts, and feature list**

Key changes:
- Architecture diagram: 2x2 panes in 1 window, not 4 windows
- Repository structure: add all missing files
- Step count: update to match actual
- Add mosh, mobile, health check, backup, webhook sections
- Update automation summary table with all cron jobs
- Update out-of-scope (remove items that are now in scope)

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/specs/2026-03-20-virtualcc-design.md
git commit -m "Update design spec to match current implementation"
```
