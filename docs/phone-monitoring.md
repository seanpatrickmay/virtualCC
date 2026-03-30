# Phone Monitoring

Check Claude Code session status from your phone via a web dashboard and push notifications.

## Quick Start

```bash
# One-time setup (generates tokens, starts services)
claude-phone-setup
```

This prints:
- A **dashboard URL** to bookmark on your phone
- An **ntfy topic** to subscribe to in the ntfy app

## Components

### Web Dashboard

A lightweight Python HTTP server that shows all offline sessions.

- **URL**: `http://<vcc-ip>:8473/<token>/`
- Dark theme, mobile-optimized, auto-refreshes every 30 seconds
- Color-coded status badges (green=running, yellow=idle, red=error, gray=completed)
- Shows session name, age, working directory, and last 5 log lines
- JSON endpoint at `/<token>/json` for programmatic access
- Runs as a systemd user service (auto-restarts on crash)

### Push Notifications

A cron job (every 2 minutes) that detects session state transitions and sends push notifications via [ntfy.sh](https://ntfy.sh).

**Notification triggers:**
| Event | Priority | Tag |
|-------|----------|-----|
| New session started | Default | rocket |
| Session completed | Default | white_check_mark |
| Session errored | Urgent (with alert sound) | rotating_light |
| Session went idle | Low | zzz |

Only state *transitions* trigger notifications -- no spam from stable states.

## Phone Setup

1. Install the [ntfy app](https://ntfy.sh) (iOS / Android)
2. Subscribe to the topic shown by `claude-phone-setup`
3. Bookmark the dashboard URL on your phone's home screen

## Configuration

Config file: `~/.config/claude-phone/config`

| Variable | Description |
|----------|-------------|
| `AUTH_TOKEN` | 32-char hex token for dashboard auth |
| `NTFY_TOPIC` | Random topic name for push notifications |
| `HTTP_PORT` | Dashboard port (default 8473) |
| `VCC_IP` | VPS public IP address |

## Security

- Dashboard uses a 128-bit random token in the URL path as authentication
- ntfy topic name is a 128-bit random string (effectively a secret URL)
- No sensitive data is exposed (only session names, status, and working directories)
- Config file is chmod 600

## Files

| File | Purpose |
|------|---------|
| `~/.local/bin/claude-phone-setup` | One-time setup script |
| `~/.local/bin/claude-phone-server` | HTTP dashboard server (Python 3, stdlib only) |
| `~/.local/bin/claude-phone-notify` | Cron notification sender |
| `~/.config/systemd/user/claude-phone-server.service` | Systemd service unit |
| `~/.config/claude-phone/config` | Generated configuration |
| `~/.local/state/claude-phone/last-state.json` | Notification state tracking |

## Troubleshooting

```bash
# Check if server is running
systemctl --user status claude-phone-server

# View server logs
tail -20 ~/.local/log/claude-phone/server.log

# View notification logs
tail -20 ~/.local/log/claude-phone/notify.log

# Restart server
systemctl --user restart claude-phone-server

# Re-run setup (preserves existing tokens)
claude-phone-setup
```
