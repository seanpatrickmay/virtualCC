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
