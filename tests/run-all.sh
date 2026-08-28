#!/bin/bash
# Run every gh-pr-enrich test suite and report a combined result.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=0

for suite in "$SCRIPT_DIR"/test-*.sh; do
    name="$(basename "$suite")"
    printf '%-34s ' "$name"
    if output=$(bash "$suite" 2>&1); then
        printf 'PASS  (%s)\n' "$(printf '%s' "$output" | grep -o 'Results: [0-9]*/[0-9]* passed' | tail -1)"
    else
        printf 'FAIL\n'
        printf '%s\n' "$output"
        FAILED=1
    fi
done

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "All suites passed."
else
    echo "One or more suites failed."
fi
exit "$FAILED"
