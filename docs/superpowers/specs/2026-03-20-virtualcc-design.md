# VirtualCC — Persistent Cloud Claude Code Environment

## Problem

Claude Code sessions die when the laptop closes. Long-running tasks are interrupted, and there's no way to reconnect from another device.

## Solution

A single Linux VPS running Claude Code inside tmux, accessible via SSH from anywhere. A bootstrap script in this repo automates the full setup from a blank Ubuntu server.

## Architecture

```
┌─────────────────────────────────────────────┐
│  VPS (Ubuntu 24.04, 2GB RAM)                │
│                                             │
│  ┌─────────────────────────────────────┐    │
│  │  tmux session "vcc"                 │    │
│  │  (auto-start, auto-attach)          │    │
│  │  ┌────────┐ ┌────────┐ ┌────────┐  │    │
│  │  │ window │ │ window │ │ window │  │    │
│  │  │   1    │ │   2    │ │   3    │  │    │
│  │  └────────┘ └────────┘ └────────┘  │    │
│  │  ┌────────┐                         │    │
│  │  │ window │                         │    │
│  │  │   4    │                         │    │
│  │  └────────┘                         │    │
│  └─────────────────────────────────────┘    │
│                                             │
│  ufw (port 22 only)                         │
│  zsh, oh-my-zsh, p10k, nvim, tmux, git,    │
│  node.js (nvm), claude code                 │
│  dotfiles (symlinked from ~/dotfiles)       │
└─────────────────────────────────────────────┘
        ▲
        │ SSH (key-only auth)
        │
   Any device (laptop, phone, tablet)
```

## Infrastructure

- **Provider:** DigitalOcean, Linode, or Hetzner (user's choice)
- **Spec:** 2GB RAM, 1-2 vCPU, Ubuntu 24.04 LTS
- **Cost:** ~$6-12/mo
- **Capacity:** 4 concurrent Claude Code sessions comfortably

## Bootstrap Script (`bootstrap.sh`)

A single idempotent script that provisions a blank Ubuntu 24.04 VPS into a fully configured development environment. Run once after VPS creation.

### Execution

```bash
# Download, inspect, then run:
ssh root@<vps-ip> 'curl -fsSL https://raw.githubusercontent.com/seanpatrickmay/virtualCC/main/bootstrap.sh -o /tmp/bootstrap.sh'
ssh root@<vps-ip> 'bash /tmp/bootstrap.sh'
```

### Steps (in order)

The script runs as root for system-level setup (steps 1-3), then switches to the `dev` user for all user-space tooling (steps 4-9). Each `dev`-user step runs via `sudo -u dev bash -c '...'` with the correct `$HOME`.

#### Phase 1: System Setup (as root)

1. **System packages**
   - `apt update && apt upgrade -y`
   - Install: `git`, `curl`, `build-essential`, `zsh`, `tmux`, `unzip`, `python3`, `ufw`, `fail2ban`

2. **Firewall**
   - `ufw allow ssh && ufw --force enable`
   - Only port 22 exposed

3. **Create `dev` user**
   - Create non-root user `dev` with sudo privileges (password required for sudo)
   - Copy SSH `authorized_keys` from root to `dev`
   - Set zsh as default shell via `chsh`

#### Phase 2: User Environment (as `dev` via `sudo -u dev`)

4. **Node.js (via nvm)**
   - Install nvm under `dev` user's `$HOME`
   - Source `~/.nvm/nvm.sh` explicitly in the same shell invocation
   - Install Node.js LTS (currently 22.x) via `nvm install --lts`

5. **Claude Code**
   - Source `~/.nvm/nvm.sh`, then `npm install -g @anthropic-ai/claude-code`

6. **Oh My Zsh + Powerlevel10k**
   - Non-interactive install: `RUNZSH=no CHSH=no sh -c "$(curl -fsSL ...)"`
   - Clone Powerlevel10k into Oh My Zsh custom themes dir
   - Note: Nerd Fonts are NOT installed on the server — the local terminal emulator must have them installed for p10k to render correctly

7. **Dotfiles**
   - Clone `seanpatrickmay/dotfiles` to `~/dotfiles`
   - Force-symlink (`ln -sf`) all config files into `$HOME`, overwriting any files created by Oh My Zsh:
     - `~/.zshrc` → `~/dotfiles/.zshrc`
     - `~/.p10k.zsh` → `~/dotfiles/.p10k.zsh`
     - `~/.vimrc` → `~/dotfiles/.vimrc`
     - `~/.tmux.conf` → `~/dotfiles/.tmux.conf`
     - `~/.config/nvim/` → `~/dotfiles/.config/nvim/`
     - `~/.vim/` → `~/dotfiles/.vim/`
     - `~/.tmux/` → `~/dotfiles/.tmux/`

8. **tmux auto-start on boot (systemd user service)**
   - Install service file to `~/.config/systemd/user/tmux-vcc.service`
   - Unit file contents:
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
   - `Type=oneshot` with `RemainAfterExit=yes` is correct because `tmux new-session -d` exits immediately after creating the detached session. The tmux server process continues independently.
   - Enable lingering and ensure the user D-Bus socket is available before starting the service:
     ```bash
     DEV_UID=$(id -u dev)
     loginctl enable-linger dev
     # Create runtime dir and wait for systemd user bus socket
     mkdir -p /run/user/$DEV_UID
     chown dev:dev /run/user/$DEV_UID
     # Wait for the user manager to initialize (linger triggers this)
     for i in $(seq 1 30); do
         [ -S /run/user/$DEV_UID/bus ] && break
         sleep 1
     done
     sudo -u dev bash -c "export XDG_RUNTIME_DIR=/run/user/$DEV_UID && systemctl --user daemon-reload && systemctl --user enable tmux-vcc.service && systemctl --user start tmux-vcc.service"
     ```
   - The service runs `tmux-session.sh` which uses truly idempotent session creation:
     ```bash
     #!/bin/bash
     # Create session if it doesn't exist
     tmux has-session -t vcc 2>/dev/null || tmux new-session -d -s vcc -n w1

     # Create additional windows only if they don't already exist
     for win in w2 w3 w4; do
         tmux list-windows -t vcc -F '#W' | grep -q "^${win}$" || \
             tmux new-window -t vcc -n "$win"
     done
     ```
   - Session name: `vcc` (used consistently in systemd service, startup script, and auto-attach logic)

9. **tmux auto-attach on SSH login**
   - Create `~/.zshrc.local` with a guarded snippet that only triggers for interactive SSH sessions, avoiding breakage of SCP/SFTP/remote commands:
     ```bash
     if [[ -z "$TMUX" && -n "$SSH_CONNECTION" && $- == *i* ]]; then
         tmux attach-session -t vcc 2>/dev/null || \
             { /home/dev/.local/bin/tmux-session.sh && tmux attach-session -t vcc; }
     fi
     ```
   - Append `[[ -f ~/.zshrc.local ]] && source ~/.zshrc.local` to the dotfiles `.zshrc` if not already present (or add it during bootstrap)
   - This keeps the auto-attach logic separate from the dotfiles repo, preventing `git pull --ff-only` from failing due to local modifications

#### Phase 3: Finalization (as root)

10. **Cron jobs**
    - All cron jobs log output to `~/.local/log/cron/` (created by bootstrap) for debugging failed runs.
    - Root crontab:
      - Weekly (Sunday 3am): `DEBIAN_FRONTEND=noninteractive apt update && apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"` (prevents interactive prompts about changed config files)
    - `dev` user crontab (with `SHELL=/bin/bash` and `HOME=/home/dev` set at top of crontab):
      - Weekly (Sunday 3:30am): Uses a wrapper script (`config/cron/update-claude`) that sources nvm via absolute path (`/home/dev/.nvm/nvm.sh`) before running `npm update -g @anthropic-ai/claude-code`. Direct `source ~/.nvm/nvm.sh` in crontab entries fails because cron uses `/bin/sh` with a minimal environment.
      - Daily (4am): `cd ~/dotfiles && git pull --ff-only || touch ~/.local/log/cron/dotfiles-sync-failed` (uses `--ff-only` to fail cleanly on conflicts; writes a sentinel file on failure that the auto-attach snippet can warn about)
    - The `~/.zshrc.local` auto-attach snippet checks for the sentinel file and prints a warning on login if dotfiles sync has failed.

11. **SSH hardening (last step)**
    - **Pre-flight check:** Verify `dev` user has a valid SSH key before proceeding:
      ```bash
      ssh-keygen -l -f /home/dev/.ssh/authorized_keys || { echo "FATAL: dev user has no valid SSH key. Aborting SSH hardening."; exit 1; }
      ```
    - Disable password authentication
    - Disable root login
    - Restart sshd
    - Note: This is deliberately the last step so root SSH access remains available for debugging if any earlier step fails. The pre-flight check prevents lockout if the authorized_keys copy in step 3 silently failed.

### Post-Bootstrap Manual Steps

After the bootstrap script completes, SSH in as `dev` and:

1. **Authenticate Claude Code:** Run `claude` in any tmux window and complete the interactive auth flow (API key or OAuth login). This cannot be automated.

## Simultaneous Connections

Multiple SSH sessions can connect simultaneously. tmux uses shared-attach by default — both clients see the same session. This is intentional: it allows monitoring from a second device. If you want independent views, open different tmux windows (`Ctrl-b 1/2/3/4`).

## Daily Workflow

### Connecting

```bash
ssh vcc
# Auto-attaches to tmux session "vcc" with 4 windows
# Ctrl-b 1/2/3/4 to switch windows
# Run `claude` in any window
```

### Disconnecting

Close the laptop, or `Ctrl-b d` to detach cleanly. Either way, all sessions persist.

### Reconnecting

```bash
ssh vcc
# Automatically reattached — everything is where you left it
```

### Local SSH Config

Add to `~/.ssh/config` on your laptop:

```
Host vcc
    HostName <your-vps-ip>
    User dev
    IdentityFile ~/.ssh/id_ed25519
```

## Automation Summary

| What | When | How |
|------|------|-----|
| tmux session creation | VPS boot | systemd user service (`tmux-vcc.service`) |
| tmux auto-attach | SSH login (interactive only) | `.zshrc` snippet with SCP/SFTP guard |
| System updates | Weekly (Sunday 3am) | root crontab |
| Claude Code updates | Weekly (Sunday 3:30am) | `dev` user crontab |
| Dotfiles sync | Daily (4am) | `dev` user crontab (`git pull --ff-only`) |
| SSH auth | Always | key-only, password disabled |
| Firewall | Always | ufw, port 22 only |

## Recovery

The VPS is stateless by design — all code lives in git repos, all config lives in this repo and the dotfiles repo. tmux sessions (running processes, scrollback) are in-memory only and will not survive a VPS termination; this is expected.

To recover:

1. Spin up a new VPS with SSH key
2. Run `bootstrap.sh`
3. SSH in as `dev`
4. Re-authenticate Claude Code (interactive — run `claude` and complete auth flow)
5. Clone your project repos

Total recovery time: ~5 minutes + auth.

## Repository Structure

```
virtualCC/
├── bootstrap.sh          # Main provisioning script
├── config/
│   ├── tmux-session.sh   # Idempotent tmux session startup (creates "vcc" with 4 windows)
│   ├── tmux-vcc.service  # systemd user service (Type=oneshot, RemainAfterExit=yes)
│   ├── zshrc.local       # tmux auto-attach snippet (installed to ~/.zshrc.local)
│   ├── sshd_config       # Hardened SSH config (key-only, no root)
│   └── cron/
│       ├── update-system  # Weekly apt upgrade (root crontab)
│       ├── update-claude  # Wrapper script: sources nvm, runs npm update (dev crontab)
│       └── sync-dotfiles  # Daily dotfiles pull (dev crontab)
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-03-20-virtualcc-design.md
```

## Out of Scope

- GUI/desktop environment
- Docker or containerization
- Multi-user access
- VPN or tailnet setup
- Automated VPS provisioning (Terraform, etc.) — manual droplet creation is fine for a single server
- Monitoring/alerting beyond optional health check
- Nerd Font installation on the server (handled by local terminal)
