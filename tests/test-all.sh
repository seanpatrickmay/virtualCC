#!/bin/bash
# Run all VCC tests. Exit non-zero if any fail.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

FAILED=0

echo "=== 1/3: Shellcheck ==="
if bash tests/shellcheck.sh; then
    echo ""
else
    FAILED=1
    echo ""
fi

echo "=== 2/3: Config Validation ==="
if bash tests/validate-configs.sh; then
    echo ""
else
    FAILED=1
    echo ""
fi

echo "=== 3/3: Docker Build (config installation) ==="
if docker build -f Dockerfile.test -t vcc-test . 2>&1 | tail -25; then
    echo ""
else
    FAILED=1
    echo ""
fi

if [ "$FAILED" -eq 0 ]; then
    echo "=== ALL TESTS PASSED ==="
else
    echo "=== SOME TESTS FAILED ==="
    exit 1
fi
