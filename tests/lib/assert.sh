#!/bin/bash
# Shared assertion helpers for gh-pr-enrich test suites.
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/assert.sh"
#   suite_start "my suite"
#   assert_eq "expected" "$actual" "description"
#   suite_end   # exits 1 if any assertion failed

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}✓${NC} $1"
    ((TESTS_PASSED++)) || true
    ((TESTS_RUN++)) || true
}

fail() {
    echo -e "${RED}✗${NC} $1"
    [ -n "${2:-}" ] && echo "  $2"
    ((TESTS_FAILED++)) || true
    ((TESTS_RUN++)) || true
}

# assert_eq EXPECTED ACTUAL DESCRIPTION
assert_eq() {
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        fail "$3" "expected: '$1' | got: '$2'"
    fi
}

# assert_true CONDITION_EXIT_CODE DESCRIPTION [DETAIL]
# Call as: some_command && rc=0 || rc=$?; assert_true "$rc" "..."
assert_true() {
    if [ "$1" -eq 0 ]; then
        pass "$2"
    else
        fail "$2" "${3:-exit code $1}"
    fi
}

# assert_contains HAYSTACK NEEDLE DESCRIPTION
assert_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then
        pass "$3"
    else
        fail "$3" "missing substring: '$2'"
    fi
}

# assert_not_contains HAYSTACK NEEDLE DESCRIPTION
assert_not_contains() {
    if printf '%s' "$1" | grep -qF -- "$2"; then
        fail "$3" "unexpected substring present: '$2'"
    else
        pass "$3"
    fi
}

# assert_jq FILE FILTER DESCRIPTION
# Passes when the jq filter yields a truthy, non-null result.
assert_jq() {
    if jq -e "$2" "$1" > /dev/null 2>&1; then
        pass "$3"
    else
        fail "$3" "jq filter failed: $2"
    fi
}

# assert_jq_eq FILE FILTER EXPECTED DESCRIPTION
assert_jq_eq() {
    local actual
    actual=$(jq -r "$2" "$1" 2>/dev/null || echo "<jq-error>")
    assert_eq "$3" "$actual" "$4"
}

suite_start() {
    echo "============================================"
    echo "$1"
    echo "============================================"
    echo ""
}

suite_end() {
    echo ""
    echo "============================================"
    echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        echo -e "${RED}$TESTS_FAILED tests failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
}
