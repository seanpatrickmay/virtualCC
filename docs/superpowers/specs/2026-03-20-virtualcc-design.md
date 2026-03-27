# VirtualCC — Persistent Cloud Claude Code Environment

## Problem

Claude Code sessions die when the laptop closes. Long-running tasks are interrupted, and there's no way to reconnect from another device.

## Solution

A single Linux VPS running Claude Code inside tmux, accessible via SSH or mosh from anywhere. A bootstrap script in this repo automates the full setup from a blank Ubuntu server.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  VPS (Ubuntu 24.04, 2GB RAM + 2GB swap)         │
│                                                 │
│  ┌───────────────────────────────────────────┐  │
│  │  tmux session "vcc" (single window)       │  │
│  │  (auto-start, auto-attach, watchdog)      │  │
│  │  ┌──────────────┬──────────────┐          │  │
│  │  │   pane 0     │   pane 2     │          │  │
│  │  │              │              │          │  │
│  │  ├──────────────┼──────────────┤          │  │
│  │  │   pane 1     │   pane 3     │          │  │
│  │  │              │              │          │  │
│  │  └──────────────┴──────────────┘          │  │
│  └───────────────────────────────────────────┘  │
│                                                 │
│  ufw (port 22, UDP 60000:60010 for mosh)        │
│  zsh, oh-my-zsh, p10k, nvim, tmux, git,        │
│  node.js (nvm), gh CLI, mosh, jq,              │
│  claude code                                    │
│  dotfiles (symlinked from ~/dotfiles)           │
│  configs managed via manifest.txt               │
└─────────────────────────────────────────────────┘
        ▲
        │ SSH (key-only auth) or mosh (UDP)
        │
   Any device (laptop, phone, tablet)
```

## Infrastructure

- **Provider:** DigitalOcean, Linode, or Hetzner (user's choice)
- **Spec:** 2GB RAM + 2GB swap, 1-2 vCPU, Ubuntu 24.04 LTS
- **Cost:** ~$6-12/mo
- **Capacity:** 4 concurrent Claude Code sessions comfortably
- **Firewall:** ufw — port 22 (SSH) + UDP 60000:60010 (mosh)

## Bootstrap Script (`bootstrap.sh`)

A single idempotent script that provisions a blank Ubuntu 24.04 VPS into a fully configured development environment. Run once after VPS creation.

### Execution

```bash
# Download, inspect, then run:
ssh root@<vps-ip> 'curl -fsSL https://raw.githubusercontent.com/seanpatrickmay/virtualCC/main/bootstrap.sh -o /tmp/bootstrap.sh'
ssh root@<vps-ip> 'DEV_PASSWORD=yourpassword bash /tmp/bootstrap.sh'
```

### Steps (in order)

The script uses an auto-incrementing step counter (12 steps total). It runs as root for system-level setup (steps 1-3), then switches to the `dev` user for all user-space tooling (steps 4-12). Each `dev`-user step runs via `sudo -u dev bash -c '...'` with the correct `$HOME`.

The virtualCC repo itself is cloned to `~/.local/share/virtualCC` early in bootstrap. Config files reference `config/manifest.txt` which defines all file installations (source, destination, mode).

#### Phase 1: System Setup (as root)

1. **System packages**
   - `apt update && apt upgrade -y`
   - Install: `git`, `curl`, `build-essential`, `zsh`, `tmux`, `unzip`, `python3`, `openssl`, `ufw`, `fail2ban`, `at`, `logrotate`, `mosh`, `jq`
   - Install neovim from GitHub releases (apt version is too old for plugins; supports x86_64 and aarch64)
   - Install GitHub CLI (`gh`) from official apt repo
   - Enable `atd` (needed for SSH hardening safety rollback)
   - Create 2GB swap file if not present (swappiness=10)

2. **Firewall**
   - `ufw allow ssh` (port 22)
   - `ufw allow 60000:60010/udp` (mosh for mobile connections)
   - `ufw --force enable`

3. **Create `dev` user**
   - Create non-root user `dev` with sudo privileges
   - Set password from `DEV_PASSWORD` env var (or generate random)
   - Save password to `/root/.vcc-dev-password` (root-readable only)
   - Copy SSH `authorized_keys` from root to `dev`
   - Set zsh as default shell via `chsh`

#### Phase 2: User Environment (as `dev` via `sudo -u dev`)

4. **Node.js (via nvm)**
   - Install nvm under `dev` user's `$HOME`
   - Source `~/.nvm/nvm.sh` explicitly in the same shell invocation
   - Install Node.js LTS (currently 22.x) via `nvm install --lts`

5. **Claude Code + config**
   - Source `~/.nvm/nvm.sh`, then `npm install -g @anthropic-ai/claude-code tree-sitter-cli`
   - Install Claude configs via manifest-based JSON merge (`config/manifest.txt`):
     - `settings.json` and `mcp_config.json` use `json-merge` mode: repo defaults are merged with any existing user config (user wins on conflicts, using `jq -s '.[0] * .[1]'`)
     - `CLAUDE.md` and `keybindings.json` use `bootstrap-only` mode: only installed if the file doesn't already exist
   - Copy `config/env.template` to `~/.env` if no `.env` exists yet

6. **Oh My Zsh + Powerlevel10k**
   - Non-interactive install: `RUNZSH=no CHSH=no sh -c "$(curl -fsSL ...)"`
   - Clone Powerlevel10k into Oh My Zsh custom themes dir
   - Clone zsh-autosuggestions and zsh-syntax-highlighting plugins
   - Note: Nerd Fonts are NOT installed on the server — the local terminal emulator must have them installed for p10k to render correctly

7. **Dotfiles**
   - Clone `seanpatrickmay/dotfiles` to `~/dotfiles`
   - Force-symlink (`ln -sf`) all config files into `$HOME`, overwriting any files created by Oh My Zsh:
     - `~/.zshrc` -> `~/dotfiles/.zshrc`
     - `~/.p10k.zsh` -> `~/dotfiles/.p10k.zsh`
     - `~/.vimrc` -> `~/dotfiles/.vimrc`
     - `~/.tmux.conf` -> `~/dotfiles/.tmux.conf`
     - `~/.config/nvim/` -> `~/dotfiles/.config/nvim/`
     - `~/.vim/` -> `~/dotfiles/.vim/`
     - `~/.tmux/` -> `~/dotfiles/.tmux/`
   - Install nvim plugins via direct git clone (PackerSync unreliable in headless mode): packer, telescope, plenary, rose-pine, treesitter, undotree, fugitive, vimtex, vim-illuminate, nvim-tree, hlchunk, lualine, nvim-web-devicons, markview
   - Pre-install treesitter parsers (lua, bash, python, javascript, typescript, c, json, html, css, yaml, toml, markdown, vim, vimdoc, query, markdown_inline)
   - Ensure dotfiles `.zshrc` sources `.zshrc.local` (appends if missing)

8. **tmux auto-start on boot (systemd user service)**
   - Install `tmux-session.sh` to `~/.local/bin/` and `tmux-vcc.service` to `~/.config/systemd/user/`
   - The service runs `tmux-session.sh` which creates a single window with a 2x2 pane grid:
     ```bash
     #!/bin/bash
     # Create session if it doesn't exist
     if ! tmux has-session -t vcc 2>/dev/null; then
         tmux new-session -d -s vcc

         # Split into 2x2 grid
         tmux split-window -h -t vcc
         tmux split-window -v -t vcc:0.0
         tmux split-window -v -t vcc:0.2

         # Even out the layout
         tmux select-layout -t vcc tiled
         tmux select-pane -t vcc:0.0
     fi
     ```
   - Uses `flock` to prevent race conditions between concurrent callers (systemd, cron watchdog, zprofile fallback)
   - Records session creation time to `~/.local/state/vcc-session-created` for reboot detection
   - Enable lingering and ensure the user D-Bus socket is available before starting the service
   - Session name: `vcc` (used consistently in systemd service, startup script, and auto-attach logic)

9. **Shell configs (via manifest)**
   - Install `zshrc.local` to `~/.zshrc.local` (aliases, functions, env loading, login status)
   - Install `zprofile.local` to `~/.zprofile.local` (tmux auto-attach before p10k instant prompt)
   - Install `logrotate.conf` to `~/.config/logrotate.conf`
   - Ensure `~/.zprofile` sources `~/.zprofile.local`

#### Phase 3: Finalization (as root)

10. **Cron jobs + scripts (via manifest)**
    - Install all executable scripts from manifest to `~/.local/bin/`
    - Install root crontab entry for weekly system updates
    - Install `dev` user crontab with `SHELL=/bin/bash` and `HOME=/home/dev` at top
    - All scripts installed from manifest use `flock` to prevent overlapping runs
    - All cron jobs log output to `~/.local/log/cron/` (created by bootstrap) for debugging
    - Backup script includes flock and 7-day rotation

11. **SSH hardening (last step)**
    - **Pre-flight check:** Verify `dev` user has a valid SSH key before proceeding
    - Install hardened sshd config to `/etc/ssh/sshd_config.d/vcc.conf`
    - Schedule automatic rollback via `at now + 5 minutes` (removes config and restarts ssh)
    - Restart sshd
    - Note: This is deliberately the last step so root SSH access remains available for debugging if any earlier step fails. The `at` rollback prevents lockout if the config is wrong.

12. **Health check + completion message**
    - Run health check to verify system state
    - Print completion message with:
      - Dev user password
      - SSH hardening rollback instructions
      - SSH config block for local machine (with `ServerAliveInterval`)
      - Mosh connection guidance for mobile
      - Port forwarding example
      - Available shell commands reference

### Post-Bootstrap Manual Steps

After the bootstrap script completes, SSH in as `dev` and:

1. **Test SSH access** in a new terminal, then cancel the 5-minute rollback: `sudo atrm $(atq | awk '{print $1}')`
2. **Authenticate Claude Code:** Run `claude` in any tmux pane and complete the interactive auth flow (API key or OAuth login). This cannot be automated.
3. **Set API keys:** Run `env-edit` to configure `GITHUB_TOKEN`, `BRAVE_API_KEY`, and optional monitoring webhooks.

## Mobile Support

The environment supports mobile access via mosh and auto-zoom:

- **mosh** (installed by default) provides UDP-based connections that survive network switches, sleep/wake, and high latency — ideal for phones and tablets
- **Auto-zoom:** When terminal width is less than 160 columns (detected at attach time in `zprofile.local`), the current pane is automatically zoomed to fill the screen, giving a single full-screen view
- **Mode switching:** Use `mobile` to zoom the current pane, `desktop` to restore the 2x2 tiled layout
- **Pane navigation:** Use `p` to list panes, `p 0` to switch to a specific pane (works in zoomed mode — unzooms, switches, re-zooms)

Recommended clients: Blink Shell (iOS), Termux (Android), `brew install mosh` (macOS)

## Shell Commands

The following aliases and functions are available in all panes (defined in `~/.zshrc.local`):

### Claude Code

| Command | Description |
|---------|-------------|
| `cc` / `c` | Launch Claude Code |
| `ccd` | Launch with `--dangerously-skip-permissions` |
| `ccr` | Resume last session |
| `ccrd` | Resume with `--dangerously-skip-permissions` |
| `ccp` | Launch in plan mode |
| `ccs` | Show Claude status |

### Navigation & Control

| Command | Description |
|---------|-------------|
| `d` | Detach from tmux (safe disconnect) |
| `p` / `p N` | List panes / switch to pane N (works in zoom mode) |
| `mobile` | Zoom current pane (single-pane view) |
| `desktop` | Restore 2x2 tiled layout |
| `bye` | Kill session and disconnect (with confirmation) |

### Utilities

| Command | Description |
|---------|-------------|
| `status` | Run health check |
| `logs` / `logs N` | View last N lines of each cron log (default 5) |
| `clone <repo>` | Clone into `~/projects/` (auto-prefixes `seanpatrickmay/` for bare names) |
| `env-edit` | Edit `~/.env` in `$EDITOR` |

## Simultaneous Connections

Multiple SSH sessions can connect simultaneously. tmux uses shared-attach by default — both clients see the same session. This is intentional: it allows monitoring from a second device. The `-d` flag in `zprofile.local` detaches stale clients on reconnect, which also fixes terminal size mismatch after SSH drops.

## Daily Workflow

### Connecting

```bash
ssh vcc
# Auto-attaches to tmux session "vcc" with 4 panes (2x2 grid)
# Navigate panes: Ctrl-b arrow keys, or use `p 0`/`p 1`/`p 2`/`p 3`
# Run `claude` (or `cc`) in any pane
```

### Connecting from mobile

```bash
mosh dev@<vps-ip>
# Auto-zooms to single pane. Use `p` to list panes, `p 0` to switch.
# Use `mobile`/`desktop` to toggle views.
```

### Disconnecting

Close the laptop, or `Ctrl-b d` (or type `d`) to detach cleanly. Either way, all sessions persist. Mosh connections survive sleep/wake automatically.

### Reconnecting

```bash
ssh vcc
# Automatically reattached — everything is where you left it
# Stale clients are detached, terminal resizes correctly
```

### Local SSH Config

Add to `~/.ssh/config` on your laptop:

```
Host vcc
    HostName <your-vps-ip>
    User dev
    ServerAliveInterval 15
    ServerAliveCountMax 2
    IdentityFile ~/.ssh/id_ed25519
```

## Automation Summary

| What | When | How |
|------|------|-----|
| tmux session creation | VPS boot | systemd user service (`tmux-vcc.service`) |
| tmux auto-attach | SSH/mosh login (interactive only) | `.zprofile.local` snippet with SCP/SFTP guard |
| tmux watchdog | Every 5 minutes | `dev` crontab — recreates session if missing |
| System updates | Weekly (Sunday 3am) | root crontab (`update-system`) |
| Claude Code updates | Weekly (Sunday 3:30am) | `dev` crontab (`update-claude`) — skips if Claude is running |
| Dotfiles sync | Daily (4am) | `dev` crontab (`sync-dotfiles`, `git pull --ff-only`) |
| VCC self-update | Daily (4:30am) | `dev` crontab (`vcc-update`) — pulls repo, re-applies manifest |
| Disk cleanup | Weekly (Sunday 2am) | `dev` crontab (`disk-cleanup`) — npm cache, old logs, tmp files |
| Log rotation | Weekly (Sunday 5am) | `dev` crontab (`logrotate`) — 4 weeks retention, compressed |
| Health check | Every 6 hours | `dev` crontab (`health-check`) — system, services, claude, env |
| Backup | Daily (5:30am) | `dev` crontab (`backup`) — .env, .claude, .gitconfig, uncommitted diffs; 7-day retention |
| SSH auth | Always | key-only, password disabled |
| Firewall | Always | ufw — port 22 + UDP 60000:60010 |

## Recovery

The VPS is designed for quick recovery — all code lives in git repos, all config is managed by this repo's manifest system, and daily backups capture non-git state (.env, .claude auth, .gitconfig, uncommitted diffs).

To recover from VPS loss:

1. Spin up a new VPS with SSH key
2. Run `bootstrap.sh`
3. SSH in as `dev`
4. Restore from backup if available (backups are in `~/.local/backups/`)
5. Re-authenticate Claude Code (interactive — run `claude` and complete auth flow)
6. Clone your project repos (or restore uncommitted diffs from backup)

Total recovery time: ~5 minutes + auth.

tmux sessions (running processes, scrollback) are in-memory only and will not survive a VPS termination; this is expected.

## Repository Structure

```
virtualCC/
├── bootstrap.sh              # Main provisioning script (12 steps, idempotent)
├── Dockerfile.test           # Docker-based test harness for CI
├── .gitignore
├── .dockerignore
├── .github/
│   └── workflows/
│       └── ci.yml            # GitHub Actions: shellcheck + config validation + docker build
├── config/
│   ├── manifest.txt          # File installation manifest (source, dest, mode)
│   ├── tmux-session.sh       # Idempotent tmux session startup (2x2 pane grid, flock)
│   ├── tmux-vcc.service      # systemd user service (Type=oneshot, RemainAfterExit=yes)
│   ├── zshrc.local           # Shell aliases, functions, env loading, login status
│   ├── zprofile.local        # tmux auto-attach (before p10k), mobile detection
│   ├── sshd_config           # Hardened SSH config (key-only, no root)
│   ├── env.template          # Template for ~/.env (API keys, monitoring webhooks)
│   ├── health-check.sh       # Comprehensive health check (system, services, claude, env)
│   ├── logrotate.conf        # Log rotation config (weekly, 4 weeks, compressed)
│   ├── claude/
│   │   ├── settings.json     # Claude Code settings (json-merge on update)
│   │   ├── mcp_config.json   # MCP server config (json-merge on update)
│   │   ├── CLAUDE.md         # Project instructions for Claude (bootstrap-only)
│   │   └── keybindings.json  # Keyboard shortcuts (bootstrap-only)
│   └── cron/
│       ├── update-system     # Weekly apt upgrade (root crontab)
│       ├── update-claude     # Weekly Claude Code npm update (skips if running)
│       ├── sync-dotfiles     # Daily dotfiles pull (sentinel on failure)
│       ├── vcc-update        # Daily self-update from GitHub (manifest-based)
│       ├── disk-cleanup      # Weekly npm cache, old logs, tmp cleanup
│       ├── tmux-watchdog     # Every 5 min — recreate session if missing
│       └── backup            # Daily backup of .env, .claude, .gitconfig, uncommitted diffs
├── tests/
│   ├── test-all.sh           # Run all test suites
│   ├── shellcheck.sh         # Shellcheck linting for all bash scripts
│   └── validate-configs.sh   # Config file validation (manifest, service, cron)
└── docs/
    └── superpowers/
        └── specs/
            └── 2026-03-20-virtualcc-design.md
```

## Out of Scope

- GUI/desktop environment
- Multi-user access
- VPN or tailnet setup
- Automated VPS provisioning (Terraform, etc.) — manual droplet creation is fine for a single server
- Nerd Font installation on the server (handled by local terminal)
