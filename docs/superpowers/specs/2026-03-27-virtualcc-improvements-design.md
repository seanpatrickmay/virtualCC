# VirtualCC Improvement Pass — Design Spec

Date: 2026-03-27
Status: Approved for implementation

## Overview

Comprehensive improvement pass across reliability, developer experience, reconnection robustness, maintainability, and feature expansion. Identified by 5 parallel analysis agents (reliability/devil's-advocate, DX, testing/maintainability, feature expansion, security).

## Section 1: Critical Bug Fixes

### 1.1 vcc-update destroys user config daily

**Problem**: `vcc-update` unconditionally `cp`s `settings.json` and `mcp_config.json`, reverting any runtime changes Claude Code or the user made (permissions, plugins, MCP servers).

**Fix**: Install `jq` in bootstrap step 1. For JSON config files, use a merge strategy: repo defaults as base, user's existing file as overlay. For first install, copy directly. Pattern:
```bash
if [ -f ~/.claude/settings.json ]; then
    jq -s '.[0] * .[1]' "$VCCDIR/config/claude/settings.json" ~/.claude/settings.json > /tmp/vcc-settings-merged.json
    mv /tmp/vcc-settings-merged.json ~/.claude/settings.json
else
    cp "$VCCDIR/config/claude/settings.json" ~/.claude/settings.json
fi
```
Apply same pattern to `mcp_config.json`. For `CLAUDE.md` and `keybindings.json`, only copy if file doesn't exist (treat as bootstrap-only).

### 1.2 update-claude runs while Claude may be active

**Problem**: `npm update -g` on Sunday 3:30 AM can replace binaries under running Claude Code processes.

**Fix**: Check for running Claude processes before updating:
```bash
if pgrep -f "claude" >/dev/null 2>&1; then
    echo "Claude Code is running, skipping update"
    exit 0
fi
```

### 1.3 Generated DEV_PASSWORD never shown or stored

**Problem**: If `DEV_PASSWORD` is auto-generated, the user never learns it. They can't sudo.

**Fix**: Print the generated password in the completion message. Save to `/root/.vcc-dev-password` with mode 600. Add a note: "Save this password — needed for sudo."

### 1.4 vcc-update overwrites itself mid-execution

**Problem**: The running script overwrites its own file. Bash reads scripts in chunks, so a significantly different new version can cause mixed old/new execution.

**Fix**: For all files that vcc-update copies, use atomic write pattern:
```bash
cp "$src" "$dst.tmp" && mv "$dst.tmp" "$dst"
```

### 1.5 bye() is dangerous

**Problem**: `bye` kills the entire tmux session (all 4 panes) without confirmation. Works even from non-tmux context.

**Fix**: Add tmux guard and confirmation. Add `d` alias for safe detach (the 90% case):
```bash
d() { tmux detach-client; }
bye() {
    [[ -z "$TMUX" ]] && { echo "Not in tmux."; return 1; }
    echo "Kill all panes and disconnect? [y/N] "
    read -r ans
    [[ "$ans" == [yY] ]] && tmux kill-session -t vcc
}
```

## Section 2: Reconnection Robustness

### 2.1 Dead client cleanup on reconnect

**Problem**: When SSH drops hard, the old tmux client registration lingers. No cleanup happens.

**Fix**: Before attaching in `zprofile.local`, detach any existing clients from the session:
```bash
# Force-detach other clients so we get a clean attachment
tmux detach-client -a -t vcc 2>/dev/null || true
```

### 2.2 Stale tmux server socket handling

**Problem**: If tmux server crashes, the socket file remains but the server is gone. `attach-session` hangs indefinitely.

**Fix**: Add a timeout to the attach attempt. If it fails, clean up the socket and try fresh:
```bash
if ! tmux has-session -t vcc 2>/dev/null; then
    # Server might be dead with stale socket — clean up
    tmux kill-server 2>/dev/null || true
    sleep 0.5
    /home/dev/.local/bin/tmux-session.sh
fi
```

### 2.3 Terminal size mismatch after device switch

**Problem**: Reconnecting from a different device/window size doesn't update the tmux display.

**Fix**: Use `attach-session -d` to detach other clients first (solves both dead-client and size issues — tmux resizes to the *last* attached client). The `-d` flag detaches all other clients before attaching:
```bash
exec tmux attach-session -d -t vcc
```
This is actually the simplest fix that solves 2.1 and 2.3 together.

### 2.4 Race condition: watchdog vs auto-attach

**Problem**: Both tmux-watchdog and zprofile.local can try to create the session simultaneously.

**Fix**: Add `flock` to `tmux-session.sh`:
```bash
exec 200>/tmp/vcc-session-create.lock
flock -w 5 200 || { echo "Session creation in progress"; exit 0; }
```

### 2.5 No fallback when exec tmux fails

**Problem**: If `exec tmux attach-session` fails (tmux binary broken, server unresponsive), the user gets disconnected with no shell.

**Fix**: Test in a subshell first, only exec if successful:
```bash
if tmux attach-session -d -t vcc </dev/null >/dev/null 2>&1 &
    ATTACH_PID=$!
    sleep 0.5
    kill -0 $ATTACH_PID 2>/dev/null
then
    kill $ATTACH_PID 2>/dev/null; wait $ATTACH_PID 2>/dev/null
    # Attach for real
    exec tmux attach-session -d -t vcc
fi
# Fallback: drop to normal shell
echo "WARNING: Could not attach to tmux session 'vcc'. Starting plain shell."
```

Actually, a simpler approach: just don't use `exec` — use a foreground attach that falls back:
```bash
tmux attach-session -d -t vcc || {
    echo "WARNING: tmux attach failed. Starting plain shell."
}
```
The downside is that detaching from tmux returns to the outer shell instead of disconnecting. But this is safer. Add `exit` after the tmux command to get the exec-like behavior while keeping the fallback:
```bash
tmux attach-session -d -t vcc && exit
echo "WARNING: Could not attach to tmux. Starting plain shell."
```

### 2.6 SSH config recommendations

Add to bootstrap completion message: full SSH config block with client-side keepalives:
```
Host vcc
    HostName <ip>
    User dev
    ServerAliveInterval 15
    ServerAliveCountMax 2
    IdentityFile ~/.ssh/id_ed25519
```

## Section 3: Developer Experience

### 3.1 Claude Code aliases (from user's local .zshrc)

Add the full set of Claude Code aliases to `zshrc.local`:
```bash
alias cc='claude'
alias ccd='claude --dangerously-skip-permissions'
alias ccr='claude --resume'
alias ccrd='claude --resume --dangerously-skip-permissions'
alias ccp='claude --plan'
alias ccs='claude status'
alias cch='claude --help'
```

### 3.2 Essential utility aliases

```bash
alias d='tmux detach-client'
alias status='~/.local/bin/health-check'
alias c='claude'
```

### 3.3 `logs` function

```bash
logs() {
    for f in ~/.local/log/cron/*.log; do
        [ -f "$f" ] || continue
        echo "=== $(basename "$f" .log) ==="
        tail -${1:-5} "$f"
        echo
    done
}
```

### 3.4 Smarter `p` function

No args: list all panes with index, command, and directory.
With arg: current behavior (switch + zoom).
```bash
p() {
    if [[ -z "$1" ]]; then
        tmux list-panes -t vcc -F '#{pane_index}: #{pane_current_command} (#{pane_current_path})' 2>/dev/null
        return
    fi
    local target="$1"
    if [[ "$(tmux display-message -p '#{window_zoomed_flag}')" == "1" ]]; then
        tmux resize-pane -Z
    fi
    tmux select-pane -t "$target"
    tmux resize-pane -Z
}
```

### 3.5 Mobile/desktop mode switching

```bash
mobile() { tmux resize-pane -Z 2>/dev/null || echo "Not in tmux"; }
desktop() {
    # Unzoom if zoomed, then restore tiled layout
    [[ "$(tmux display-message -p '#{window_zoomed_flag}')" == "1" ]] && tmux resize-pane -Z
    tmux select-layout -t vcc tiled
}
```

### 3.6 Show pane index in all panes

Minimal indicator in panes 1-3, full status in pane 0:
```bash
_pane_idx=$(tmux display-message -p '#{pane_index}' 2>/dev/null)
if [[ "$_pane_idx" == "0" ]]; then
    _vcc_status  # full status (existing)
else
    echo -e "\033[90m[vcc:pane${_pane_idx}]\033[0m"
fi
```

### 3.7 Failure sentinel files for all cron jobs

Add sentinels to `vcc-update` and `update-claude` matching the existing `sync-dotfiles` pattern. Check all in `_vcc_status`:
```bash
[[ -f ~/.local/log/cron/vcc-update-failed ]] && warn="$warn | ⚠ vcc self-update failed"
[[ -f ~/.local/log/cron/update-claude-failed ]] && warn="$warn | ⚠ claude update failed"
```

### 3.8 Raise auto-zoom threshold to 160 cols

At 120 cols, the 2x2 grid gives 60-col panes — code wraps. 160 cols gives 80+ per pane.

### 3.9 User hook files that survive updates

- `~/.config/vcc/tmux-custom.sh` — sourced after standard tmux setup
- `~/.zshrc.user` — sourced at end of zshrc.local
- Neither file is managed by vcc-update.

### 3.10 Session-created timestamp for reboot detection

In `tmux-session.sh`, after creating the session:
```bash
date > ~/.local/state/vcc-session-created
```
In `_vcc_status`, check if created within last 10 minutes and show notice.

### 3.11 env-edit helper

```bash
env-edit() { ${EDITOR:-nvim} ~/.env && echo "Restart your shell or run: source ~/.zshrc.local"; }
```

### 3.12 Improved bootstrap completion message

- Full SSH config block with keepalive and IP pre-filled
- Mosh client install guidance (brew, Blink Shell, Termux)
- Print generated DEV_PASSWORD
- Port forwarding example: `ssh -L 3000:localhost:3000 vcc`

## Section 4: Reliability Hardening

### 4.1 Unify tmux session management

Remove the dual-management conflict between systemd service and watchdog. Keep systemd for boot-time creation, make watchdog the recovery mechanism. Add coordination via session-creation lock.

### 4.2 flock on cron jobs

Wrap each cron entry in `flock -n /tmp/vcc-<name>.lock`. Prevents overlapping runs.

### 4.3 Health check: set XDG_RUNTIME_DIR

Add to health-check.sh:
```bash
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
```

### 4.4 Bootstrap: fix existing dev user

Move `usermod -aG sudo`, `chsh -s /usr/bin/zsh`, and `chpasswd` outside the `if ! id` block so re-runs fix a pre-existing user.

### 4.5 disk-cleanup: safer /tmp handling

Add `-type f`, increase threshold to 30 days.

### 4.6 update-system: fix log ownership

The root cron job writes to dev's home dir as root. Fix: `chown dev:dev` the log file after writing, or redirect through `su dev`.

## Section 5: Maintainability

### 5.1 File manifest

Create `config/manifest.txt` listing source→destination mappings. Read by bootstrap.sh, vcc-update, and validate-configs.sh. Adding a new config file or cron job requires updating only the script + manifest.

Format:
```
# source                          destination                      mode
config/cron/update-claude         ~/.local/bin/update-claude       +x
config/cron/sync-dotfiles         ~/.local/bin/sync-dotfiles       +x
config/health-check.sh            ~/.local/bin/health-check        +x
config/tmux-session.sh            ~/.local/bin/tmux-session.sh     +x
config/zshrc.local                ~/.zshrc.local                   644
config/zprofile.local             ~/.zprofile.local                644
config/logrotate.conf             ~/.config/logrotate.conf         644
```

### 5.2 Centralize version constants

Create a `config/versions.env` or put at top of bootstrap.sh:
```bash
NVIM_VERSION="v0.11.4"
NVM_VERSION="v0.40.1"
SESSION_NAME="vcc"
DEV_USER="dev"
```

Dockerfile.test reads the same versions via ARG or build-time extraction.

### 5.3 Auto-incrementing step counter

Replace hard-coded `[1/12]` with:
```bash
STEP=0; TOTAL=12
step() { STEP=$((STEP + 1)); echo "[$STEP/$TOTAL] $1"; }
```

### 5.4 GitHub Actions CI

```yaml
jobs:
  lint:     # shellcheck + validate-configs + zsh -n
  docker:   # Docker build test
```
Trigger on push and PR.

### 5.5 Plugin list consistency check

Add to validate-configs.sh: extract plugin lists from bootstrap.sh and Dockerfile.test, diff them.

### 5.6 Update design spec

Bring `2026-03-20-virtualcc-design.md` in line with current reality (2x2 panes not windows, all missing files/features, correct step count, mosh/mobile support).

## Section 6: Features

### 6.1 Local backup cron

New `config/cron/backup` script. Tars `~/.env`, `~/.claude/` (auth state), `~/.gitconfig`, uncommitted git diffs from `~/projects/` into `~/.local/backups/` with 7-day rotation. Follows existing cron script pattern.

### 6.2 Webhook alerts on health degradation

At end of `health-check.sh`, if `STATUS > 0` and `VCC_ALERT_WEBHOOK` is set in env:
```bash
if [[ "$STATUS" -gt 0 && -n "${VCC_ALERT_WEBHOOK:-}" ]]; then
    curl -s -H "Content-Type: application/json" \
        -d "{\"content\":\"VCC Health: $LABEL on $(hostname) — $(date)\"}" \
        "$VCC_ALERT_WEBHOOK" || true
fi
```
Fully opt-in via env var. Works with Discord, Slack, or any webhook endpoint.

### 6.3 Uptime ping

Piggyback on health-check cron. If `VCC_HEALTHCHECK_PING_URL` is set:
```bash
[[ -n "${VCC_HEALTHCHECK_PING_URL:-}" ]] && curl -fsS --retry 3 "$VCC_HEALTHCHECK_PING_URL" || true
```
Catches the case health-check itself can't detect: VPS is down.

### 6.4 Clone helper

```bash
clone() {
    local repo="$1" dest="${2:-}"
    [[ -z "$repo" ]] && { echo "Usage: clone <repo> [dir]"; return 1; }
    [[ "$repo" != */* ]] && repo="seanpatrickmay/$repo"
    [[ "$repo" != https://* && "$repo" != git@* ]] && repo="https://github.com/$repo"
    local name="${dest:-$(basename "$repo" .git)}"
    mkdir -p ~/projects
    git clone "$repo" ~/projects/"$name" && cd ~/projects/"$name"
}
```

### 6.5 gh auth setup-git

Add `gh auth setup-git` after Claude Code installation in bootstrap. Enables git HTTPS push/pull with GITHUB_TOKEN.

### 6.6 Add env vars for new features

Update `config/env.template`:
```
VCC_ALERT_WEBHOOK=
VCC_HEALTHCHECK_PING_URL=
```

## Implementation Order

1. Critical bug fixes (Section 1) — must ship first
2. Reconnection robustness (Section 2) — high user impact
3. Maintainability infrastructure (Section 5.1-5.3) — makes remaining work easier
4. DX improvements (Section 3) — most numerous, parallelize
5. Reliability hardening (Section 4) — defense in depth
6. Features (Section 6) — new capabilities
7. CI + spec update (Section 5.4-5.6) — finalization
