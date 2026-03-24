#!/bin/bash
# Validates config consistency across the project.
# Catches drift between bootstrap.sh and vcc-update,
# missing files, broken JSON, and step counter issues.

set -uo pipefail

FAILED=0
PASSED=0

check() {
    local name="$1" result="$2"
    if [ "$result" -eq 0 ]; then
        echo "  ✓ $name"
        PASSED=$((PASSED + 1))
    else
        echo "  ✗ $name"
        FAILED=$((FAILED + 1))
    fi
}

echo "=== VCC Config Validation ==="
echo ""

# --- JSON validation ---
echo "JSON configs:"
for f in config/claude/*.json; do
    if python3 -c "import json; json.load(open('$f'))" 2>/dev/null; then
        check "$f: valid" 0
    else
        check "$f: INVALID JSON" 1
    fi
done

echo ""

# --- Script existence ---
echo "Scripts referenced in shellcheck.sh exist:"
# shellcheck disable=SC2013
for script in $(grep -E '^\s+"' tests/shellcheck.sh | tr -d '",' | xargs); do
    if [ -f "$script" ]; then
        check "$script" 0
    else
        check "$script: MISSING" 1
    fi
done

echo ""

# --- Bootstrap vs vcc-update consistency ---
echo "Bootstrap/vcc-update install the same scripts:"

# Extract script names installed to ~/.local/bin from both files
BOOTSTRAP_SCRIPTS=$(grep -o 'cp.*~/.local/bin/[a-z_-]*' bootstrap.sh | sed 's/.*~\/.local\/bin\///' | sort -u)
UPDATE_SCRIPTS=$(grep -o 'cp.*~/.local/bin/[a-z_-]*' config/cron/vcc-update | sed 's/.*~\/.local\/bin\///' | sort -u)

# Check for scripts in bootstrap but not in vcc-update
for s in $BOOTSTRAP_SCRIPTS; do
    if echo "$UPDATE_SCRIPTS" | grep -q "^${s}$"; then
        check "  $s: synced" 0
    else
        check "  $s: in bootstrap but NOT in vcc-update" 1
    fi
done

# Check for scripts in vcc-update but not in bootstrap
for s in $UPDATE_SCRIPTS; do
    if ! echo "$BOOTSTRAP_SCRIPTS" | grep -q "^${s}$"; then
        check "  $s: in vcc-update but NOT in bootstrap" 1
    fi
done

echo ""

# --- Bootstrap step counter ---
echo "Step counter consistency:"
STEP_COUNTS=$(grep -oP '\[\d+/\d+\]' bootstrap.sh 2>/dev/null || grep -oE '\[[0-9]+/[0-9]+\]' bootstrap.sh)
TOTAL=$(echo "$STEP_COUNTS" | head -1 | sed 's/.*\///' | tr -d ']')
MISMATCHES=$(echo "$STEP_COUNTS" | grep -v "/$TOTAL]" || true)
if [ -z "$MISMATCHES" ]; then
    check "All steps use /$TOTAL] consistently" 0
else
    check "Inconsistent step totals: $MISMATCHES" 1
fi

echo ""

# --- Config files that bootstrap copies are also in vcc-update ---
echo "Config file sync consistency:"

# Claude config files
for f in settings.json mcp_config.json CLAUDE.md keybindings.json; do
    BS=$(grep -c "$f" bootstrap.sh)
    VU=$(grep -c "$f" config/cron/vcc-update)
    if [ "$BS" -gt 0 ] && [ "$VU" -gt 0 ]; then
        check "$f: in both" 0
    elif [ "$BS" -gt 0 ] && [ "$VU" -eq 0 ]; then
        check "$f: in bootstrap but NOT in vcc-update" 1
    fi
done

# Shell configs
for f in zshrc.local zprofile.local logrotate.conf; do
    BS=$(grep -c "$f" bootstrap.sh)
    VU=$(grep -c "$f" config/cron/vcc-update)
    if [ "$BS" -gt 0 ] && [ "$VU" -gt 0 ]; then
        check "$f: in both" 0
    elif [ "$BS" -gt 0 ] && [ "$VU" -eq 0 ]; then
        check "$f: in bootstrap but NOT in vcc-update" 1
    fi
done

echo ""

# --- Cron jobs reference existing scripts ---
echo "Cron job targets exist:"
for script in config/cron/*; do
    [ -f "$script" ] || continue
    NAME=$(basename "$script")
    check "$NAME" 0
done

echo ""
echo "=== Results: $PASSED passed, $FAILED failed ==="

if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
