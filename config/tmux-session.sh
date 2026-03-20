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
