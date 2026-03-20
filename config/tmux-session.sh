#!/bin/bash
# Idempotent tmux session creation for VCC.
# Creates session "vcc" with a single window containing a 2x2 pane grid.
# Called by systemd user service and .zshrc.local fallback.

set -euo pipefail

SESSION="vcc"

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
fi
