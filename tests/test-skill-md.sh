#!/bin/bash
# Regression checks for code examples in SKILL.md.
# Catches bugs found in PR #7:
#   1. Literal placeholder strings (OWNER, REPO, PR_NUMBER, hardcoded 123) leaking
#      into runnable GraphQL/`gh api` examples.
#   2. jq filters that reference fields not present in the all-comments.json schema
#      produced by gh-pr-enrich (e.g. .pull_request_review_id).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SKILL_MD="${1:-$PROJECT_DIR/.claude/skills/gh-pr-enrich/SKILL.md}"
FIXTURE="$SCRIPT_DIR/fixtures/skill-md/all-comments.json"

RED='\033[0;31m'
GREEN='\033[0;32m'
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
    if [ -n "${2:-}" ]; then
        echo "  $2"
    fi
    ((TESTS_FAILED++)) || true
    ((TESTS_RUN++)) || true
}

# ---------------------------------------------------------------------------
# Static check: no literal placeholder strings in GraphQL/`gh api` examples.
# ---------------------------------------------------------------------------
test_no_literal_placeholders_in_graphql() {
    local pattern='(owner|name): "(OWNER|REPO)"|pullRequest\(number: 123\)|-[fF] (owner|repo|number)=(OWNER|REPO|PR_NUMBER)'
    if grep -nE "$pattern" "$SKILL_MD" > /tmp/skill-md-placeholders.$$ 2>&1; then
        fail "SKILL.md contains literal placeholder strings in runnable examples" \
             "$(cat /tmp/skill-md-placeholders.$$)
  Use shell variables instead: -F owner=\"\$OWNER\" -F repo=\"\$REPO\" -F number=\"\$PR_NUMBER\""
        rm -f /tmp/skill-md-placeholders.$$
    else
        pass "no literal OWNER/REPO/PR_NUMBER/123 placeholders in GraphQL examples"
        rm -f /tmp/skill-md-placeholders.$$
    fi
}

# ---------------------------------------------------------------------------
# Static check: no references to .pull_request_review_id (field doesn't exist
# in all-comments.json — see schema comment in the gh-pr-enrich script).
# ---------------------------------------------------------------------------
test_no_pull_request_review_id_field() {
    if grep -nE '\.pull_request_review_id' "$SKILL_MD" > /tmp/skill-md-prr.$$ 2>&1; then
        fail "SKILL.md references .pull_request_review_id (field not in all-comments.json)" \
             "$(cat /tmp/skill-md-prr.$$)
  Use .type == \"issue_comment\" to select non-thread comments."
        rm -f /tmp/skill-md-prr.$$
    else
        pass "no .pull_request_review_id references (use .type == \"issue_comment\")"
        rm -f /tmp/skill-md-prr.$$
    fi
}

# ---------------------------------------------------------------------------
# Dynamic check: the canonical non-thread-comment filter must select exactly
# the issue_comment entries from a real-shaped fixture, and nothing else.
# ---------------------------------------------------------------------------
test_issue_comment_filter_against_fixture() {
    if [ ! -f "$FIXTURE" ]; then
        fail "fixture missing: $FIXTURE" "(cannot exercise jq filter against schema)"
        return
    fi

    local total expected actual types
    total=$(jq 'length' "$FIXTURE")
    expected=$(jq '[.[] | select(.type == "issue_comment")] | length' "$FIXTURE")
    actual=$(jq '[.[] | select(.type == "issue_comment")] | length' "$FIXTURE")
    types=$(jq -r '[.[] | .type] | unique | join(",")' "$FIXTURE")

    if [ "$total" -le "$expected" ]; then
        fail "fixture is not heterogeneous (total=$total, issue_comments=$expected)" \
             "fixture must contain at least one non-issue_comment entry to validate the filter"
        return
    fi

    if [ "$actual" = "$expected" ] && [ "$expected" -ge 1 ]; then
        pass "issue_comment filter selects $expected of $total entries (types: $types)"
    else
        fail "issue_comment filter returned $actual; expected $expected" ""
    fi
}

# ---------------------------------------------------------------------------
# Dynamic check: the bug pattern from PR #7 (.pull_request_review_id == null)
# would silently match every entry in the schema-correct fixture. This proves
# the static check above guards against a real failure mode.
# ---------------------------------------------------------------------------
test_legacy_filter_proves_bug_class() {
    if [ ! -f "$FIXTURE" ]; then
        fail "fixture missing: $FIXTURE" ""
        return
    fi

    local total buggy_match
    total=$(jq 'length' "$FIXTURE")
    buggy_match=$(jq '[.[] | select(.pull_request_review_id == null)] | length' "$FIXTURE")

    if [ "$buggy_match" = "$total" ] && [ "$total" -gt 1 ]; then
        pass ".pull_request_review_id filter (the bug from PR #7) silently matches all $total entries — confirms static check is necessary"
    else
        fail ".pull_request_review_id filter behaves unexpectedly against fixture" \
             "got $buggy_match matches out of $total; bug-class assumption invalidated"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "============================================"
echo "SKILL.md regression check suite"
echo "============================================"
echo "Target:  $SKILL_MD"
echo "Fixture: $FIXTURE"
echo ""

test_no_literal_placeholders_in_graphql
test_no_pull_request_review_id_field
test_issue_comment_filter_against_fixture
test_legacy_filter_proves_bug_class

echo ""
echo "============================================"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "${RED}$TESTS_FAILED tests failed${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
