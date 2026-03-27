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

# --- Manifest source files exist ---
echo "Manifest source files exist:"
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    src=$(echo "$line" | awk '{print $1}')
    if [ -f "$src" ]; then
        check "$src" 0
    else
        check "$src: MISSING" 1
    fi
done < config/manifest.txt

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

# --- Nvim plugin list consistency (bootstrap vs Dockerfile) ---
echo "Nvim plugin list consistency (bootstrap vs Dockerfile):"
# Bootstrap uses 'clone user/repo' pattern for plugins
BOOTSTRAP_PLUGINS=$(grep -oE 'clone [a-zA-Z0-9_-]+/[a-zA-Z0-9._-]+' bootstrap.sh | sed 's/clone //' | sort)
# Dockerfile clones plugins under PLUGIN_DIR
DOCKER_PLUGINS=$(sed -n '/PLUGIN_DIR/,/^[^[:space:]]/p' Dockerfile.test | grep -oE 'github\.com/[a-zA-Z0-9_-]+/[a-zA-Z0-9._-]+' | sed 's|github\.com/||' | sort)
if [ "$BOOTSTRAP_PLUGINS" = "$DOCKER_PLUGINS" ]; then
    check "Plugin lists match" 0
else
    check "Plugin lists DIFFER" 1
fi

echo ""

# --- Bootstrap and vcc-update use manifest ---
echo "Bootstrap and vcc-update use manifest:"
BS_MANIFEST=$(grep -c "manifest.txt" bootstrap.sh)
VU_MANIFEST=$(grep -c "manifest.txt" config/cron/vcc-update)
if [ "$BS_MANIFEST" -gt 0 ] && [ "$VU_MANIFEST" -gt 0 ]; then
    check "Both reference manifest.txt" 0
else
    if [ "$BS_MANIFEST" -eq 0 ]; then check "bootstrap.sh: missing manifest reference" 1; fi
    if [ "$VU_MANIFEST" -eq 0 ]; then check "vcc-update: missing manifest reference" 1; fi
fi

echo ""

# --- Bootstrap step counter ---
echo "Step counter consistency:"
# bootstrap.sh now uses step() function with TOTAL variable
TOTAL_VAR=$(grep -oE 'TOTAL=[0-9]+' bootstrap.sh | head -1 | sed 's/TOTAL=//')
STEP_CALLS=$(grep -c '^step ' bootstrap.sh 2>/dev/null || grep -c 'step "' bootstrap.sh)
if [ "$STEP_CALLS" = "$TOTAL_VAR" ]; then
    check "step() calls ($STEP_CALLS) match TOTAL=$TOTAL_VAR" 0
else
    check "step() calls ($STEP_CALLS) != TOTAL ($TOTAL_VAR)" 1
fi

echo ""

# --- All manifest files are referenced in manifest.txt ---
echo "Manifest covers all config files:"
# Verify key config files are listed in the manifest
for f in settings.json mcp_config.json CLAUDE.md keybindings.json zshrc.local zprofile.local logrotate.conf; do
    if grep -q "$f" config/manifest.txt; then
        check "$f: in manifest" 0
    else
        check "$f: MISSING from manifest" 1
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
