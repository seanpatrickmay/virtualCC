#!/bin/bash
# VCC health check. Reports on system, services, and sessions.
# Can be run manually or via cron for monitoring.
# Exit code 0 = healthy, 1 = degraded, 2 = critical.

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

STATUS=0

check() {
    local name="$1" result="$2" severity="$3"
    if [ "$result" -eq 0 ]; then
        echo -e "  ${GREEN}✓${NC} $name"
    elif [ "$severity" = "warn" ]; then
        echo -e "  ${YELLOW}⚠${NC} $name"
        [ "$STATUS" -lt 1 ] && STATUS=1
    else
        echo -e "  ${RED}✗${NC} $name"
        [ "$STATUS" -lt 2 ] && STATUS=2
    fi
}

echo "=== VCC Health Check: $(date) ==="
echo ""

# --- System ---
echo "System:"

# Disk usage (warn >80%, critical >90%)
DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,""); print $5}')
if [ "$DISK_PCT" -ge 90 ]; then
    check "Disk: ${DISK_PCT}% used (CRITICAL — above 90%)" 1 "critical"
elif [ "$DISK_PCT" -ge 80 ]; then
    check "Disk: ${DISK_PCT}% used (above 80%)" 1 "warn"
else
    check "Disk: ${DISK_PCT}% used" 0 ""
fi

# Memory (warn if swap >50% used)
if command -v free &>/dev/null; then
    MEM_TOTAL=$(free -m | awk '/Mem:/ {print $2}')
    MEM_USED=$(free -m | awk '/Mem:/ {print $3}')
    SWAP_TOTAL=$(free -m | awk '/Swap:/ {print $2}')
    SWAP_USED=$(free -m | awk '/Swap:/ {print $3}')
    check "Memory: ${MEM_USED}/${MEM_TOTAL}MB" 0 ""
    if [ "$SWAP_TOTAL" -gt 0 ]; then
        SWAP_PCT=$((SWAP_USED * 100 / SWAP_TOTAL))
        if [ "$SWAP_PCT" -ge 50 ]; then
            check "Swap: ${SWAP_USED}/${SWAP_TOTAL}MB (${SWAP_PCT}% — heavy swapping)" 1 "warn"
        else
            check "Swap: ${SWAP_USED}/${SWAP_TOTAL}MB" 0 ""
        fi
    else
        check "Swap: not configured (recommend 2-4GB for long tasks)" 1 "warn"
    fi
fi

# Uptime
if command -v uptime &>/dev/null; then
    UP=$(uptime -p 2>/dev/null || uptime)
    check "Uptime: $UP" 0 ""
fi

echo ""

# --- Services ---
echo "Services:"

# tmux session
if tmux has-session -t vcc 2>/dev/null; then
    PANE_COUNT=$(tmux list-panes -t vcc 2>/dev/null | wc -l | tr -d ' ')
    check "tmux 'vcc' session: ${PANE_COUNT} panes" 0 ""
else
    check "tmux 'vcc' session: not running" 1 "critical"
fi

# systemd service (only if systemd available)
if command -v systemctl &>/dev/null; then
    if systemctl --user is-active tmux-vcc.service &>/dev/null; then
        check "tmux-vcc.service: active" 0 ""
    else
        check "tmux-vcc.service: inactive" 1 "warn"
    fi
fi

# SSH
if command -v systemctl &>/dev/null && systemctl is-active ssh &>/dev/null; then
    check "SSH: running" 0 ""
elif command -v systemctl &>/dev/null; then
    check "SSH: not running" 1 "critical"
fi

# Firewall (requires root)
if command -v ufw &>/dev/null; then
    if [ "$(id -u)" -eq 0 ]; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            check "Firewall (ufw): active" 0 ""
        else
            check "Firewall (ufw): inactive" 1 "warn"
        fi
    else
        check "Firewall (ufw): skipped (requires root)" 0 ""
    fi
fi

echo ""

# --- Claude Code ---
echo "Claude Code:"

# Load nvm so claude is on PATH (non-interactive shells don't source .zshrc)
if [ -s "$HOME/.nvm/nvm.sh" ]; then
    export NVM_DIR="$HOME/.nvm"
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh"
    check "nvm: loaded" 0 ""
else
    check "nvm: not found" 1 "warn"
fi

# Check if claude is installed (timeout to prevent hanging in non-tty)
if command -v claude &>/dev/null; then
    CLAUDE_VER=$(timeout 5 claude --version 2>/dev/null || echo "unknown")
    check "Installed: $CLAUDE_VER" 0 ""
else
    check "Not installed" 1 "critical"
fi

# Check gh CLI
if command -v gh &>/dev/null; then
    GH_VER=$(gh --version 2>/dev/null | head -1 || echo "unknown")
    check "gh CLI: $GH_VER" 0 ""
else
    check "gh CLI: not installed (PR/issue workflows won't work)" 1 "warn"
fi

# Check mosh
if command -v mosh-server &>/dev/null; then
    check "mosh-server: installed" 0 ""
else
    check "mosh-server: not installed (phone access won't work)" 1 "warn"
fi

echo ""

# --- Environment ---
echo "Environment:"

if [ -f "$HOME/.env" ]; then
    # Check for non-empty GITHUB_TOKEN
    if grep -q 'GITHUB_TOKEN=.' "$HOME/.env" 2>/dev/null; then
        check "GITHUB_TOKEN: set" 0 ""
    else
        check "GITHUB_TOKEN: not set (MCP github server won't work)" 1 "warn"
    fi
    # Check for non-empty BRAVE_API_KEY
    if grep -q 'BRAVE_API_KEY=.' "$HOME/.env" 2>/dev/null; then
        check "BRAVE_API_KEY: set" 0 ""
    else
        check "BRAVE_API_KEY: not set (MCP brave-search won't work)" 1 "warn"
    fi
else
    check "$HOME/.env: not found (API keys not configured)" 1 "warn"
fi

echo ""

# --- Cron logs ---
echo "Maintenance:"

LOG_DIR="$HOME/.local/log/cron"
if [ -d "$LOG_DIR" ]; then
    for log in "$LOG_DIR"/*.log; do
        [ -f "$log" ] || continue
        NAME=$(basename "$log" .log)
        SIZE=$(du -sh "$log" 2>/dev/null | awk '{print $1}')
        LAST=$(tail -1 "$log" 2>/dev/null | head -c 80)
        check "$NAME log: $SIZE — last: $LAST" 0 ""
    done

    # Check sentinel files
    if [ -f "$LOG_DIR/dotfiles-sync-failed" ]; then
        check "Dotfiles sync: FAILED (sentinel present)" 1 "warn"
    fi
else
    check "Cron log dir: not found (cron may not be set up)" 1 "warn"
fi

echo ""
if [ "$STATUS" -eq 0 ]; then
    LABEL="HEALTHY"
elif [ "$STATUS" -eq 1 ]; then
    LABEL="DEGRADED"
else
    LABEL="CRITICAL"
fi
echo "=== Status: $LABEL ==="

exit "$STATUS"
