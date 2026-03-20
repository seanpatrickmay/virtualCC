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
