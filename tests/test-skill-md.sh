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
SKILL_DIR="${1:-$PROJECT_DIR/.claude/skills/gh-pr-enrich}"
SKILL_MD="$SKILL_DIR/SKILL.md"
FIXTURE="$SCRIPT_DIR/fixtures/skill-md/all-comments.json"

# Every documentation file that can carry a runnable example. Reference files are
# split out of SKILL.md but are read and run by agents just the same.
SKILL_DOCS=("$SKILL_MD")
while IFS= read -r ref; do
    [ -n "$ref" ] && SKILL_DOCS+=("$ref")
done < <(find "$SKILL_DIR/references" -name '*.md' 2>/dev/null | sort)

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
    if grep -nE "$pattern" "${SKILL_DOCS[@]}" > /tmp/skill-md-placeholders.$$ 2>&1; then
        fail "skill docs contain literal placeholder strings in runnable examples" \
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
    if grep -nE '\.pull_request_review_id' "${SKILL_DOCS[@]}" > /tmp/skill-md-prr.$$ 2>&1; then
        fail "skill docs reference .pull_request_review_id (field not in all-comments.json)" \
             "$(cat /tmp/skill-md-prr.$$)
  Use .type == \"issue_comment\" to select non-thread comments."
        rm -f /tmp/skill-md-prr.$$
    else
        pass "no .pull_request_review_id references (use .type == \"issue_comment\")"
        rm -f /tmp/skill-md-prr.$$
    fi
}

# ---------------------------------------------------------------------------
# Dynamic check: extract the non-thread-comment jq filter from SKILL.md and
# run it against a fixture with known contents. Expected values are hardcoded
# from the fixture (count=1, id=1001) so the assertion is independent of the
# extracted filter — a regression in either SKILL.md or the filter behavior
# fails the test.
#
# The fixture has 3 entries: id=1001 (issue_comment), 2001 (review_comment),
# 3001 (inline_comment). Any correct issue_comment selector returns exactly
# one entry whose id is 1001. The buggy `.pull_request_review_id == null`
# filter from PR #7 returns all three (count=3, first_id=1001), failing the
# count assertion.
# ---------------------------------------------------------------------------
test_skill_md_issue_comment_filter() {
    if [ ! -f "$FIXTURE" ]; then
        fail "fixture missing: $FIXTURE" "(cannot exercise jq filter against schema)"
        return
    fi

    # Sanity-check the fixture matches the contract this test relies on.
    local fixture_count fixture_first_issue_id
    fixture_count=$(jq 'length' "$FIXTURE")
    fixture_first_issue_id=$(jq -r 'first(.[] | select(.type == "issue_comment") | .id)' "$FIXTURE")
    if [ "$fixture_count" != "3" ] || [ "$fixture_first_issue_id" != "1001" ]; then
        fail "fixture contract violated" \
             "expected 3 entries with issue_comment id=1001; got count=$fixture_count, first_issue_id=$fixture_first_issue_id"
        return
    fi

    # Extract the jq filter from SKILL.md's non-thread-comment example.
    # The example has the form: jq '[.[] | select(.type == "...")]' followed
    # (often on a continuation line) by `pr-$PR_NUMBER/all-comments.json`.
    # We capture the body inside the first single-quoted argument that uses
    # the array-iteration + .type discriminator pattern.
    local filter
    filter=$(grep -hoE "jq '\[\.\[\] \| select\(\.type [^']+\)\]'" "${SKILL_DOCS[@]}" \
             | head -1 \
             | sed -E "s/^jq '(.*)'\$/\\1/")

    if [ -z "$filter" ]; then
        fail "could not extract issue_comment filter from the skill docs" \
             "expected a line of the form: jq '[.[] | select(...)]' ... pr-\$PR_NUMBER/all-comments.json"
        return
    fi

    # Hardcoded expected values from the fixture.
    local expected_count=1
    local expected_id=1001
    local actual_count actual_id
    actual_count=$(jq "($filter) | length" "$FIXTURE" 2>/dev/null) || {
        fail "extracted jq filter failed to parse" "filter: $filter"
        return
    }
    actual_id=$(jq -r "($filter)[0].id // \"\"" "$FIXTURE" 2>/dev/null)

    if [ "$actual_count" = "$expected_count" ] && [ "$actual_id" = "$expected_id" ]; then
        pass "skill-doc filter \`$filter\` selects exactly the issue_comment entry (count=$expected_count, id=$expected_id)"
    else
        fail "skill-doc filter does not select the expected issue_comment entry" \
             "filter: $filter
  expected count=$expected_count, id=$expected_id
  actual   count=$actual_count, id=$actual_id"
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
# Every references/ link in SKILL.md must point at a file that exists, and every
# reference file must be linked. A split that loses a pointer hides the content.
# ---------------------------------------------------------------------------
test_reference_links_resolve() {
    local missing="" linked_count=0 ref target
    while IFS= read -r target; do
        [ -z "$target" ] && continue
        linked_count=$((linked_count + 1))
        [ -f "$SKILL_DIR/$target" ] || missing="$missing $target"
    done < <(grep -oE '\(references/[a-z0-9-]+\.md\)' "$SKILL_MD" | tr -d '()' | sort -u)

    if [ -n "$missing" ]; then
        fail "SKILL.md links to reference files that do not exist" "missing:$missing"
    elif [ "$linked_count" -eq 0 ]; then
        fail "SKILL.md links to no reference files" "expected pointers to references/*.md"
    else
        pass "all $linked_count reference links in SKILL.md resolve"
    fi

    local unlinked=""
    for ref in "$SKILL_DIR"/references/*.md; do
        [ -f "$ref" ] || continue
        grep -q "references/$(basename "$ref")" "$SKILL_MD" || unlinked="$unlinked $(basename "$ref")"
    done

    if [ -n "$unlinked" ]; then
        fail "reference files exist that SKILL.md never points at" "orphaned:$unlinked"
    else
        pass "every reference file is linked from SKILL.md"
    fi
}

# Review-only interpretation guidance must never contain hosted-state mutation
# commands or tell agents to execute analyzer-provided verification strings.
test_analysis_reference_stays_read_only() {
    local analysis_reference="$SKILL_DIR/references/analysis-output.md"
    if grep -nE 'resolveReviewThread|addPullRequestReviewThreadReply|gh pr-enrich resolve' \
        "$analysis_reference" > /tmp/skill-md-mutations.$$ 2>&1; then
        fail "analysis-output.md contains remediation commands" \
            "$(cat /tmp/skill-md-mutations.$$)"
    else
        pass "analysis-output.md keeps hosted mutations behind remediation.md"
    fi
    rm -f /tmp/skill-md-mutations.$$

    if grep -q 'Run the stated `verification`' "$analysis_reference"; then
        fail "analysis-output.md executes analyzer-provided verification text" ""
    else
        pass "analysis-output.md treats analyzer verification text as untrusted"
    fi
}

# A generic request to fix findings does not authorize commits, pushes, review
# replies, or thread resolution. The remediation guide must preserve that split.
test_remediation_authorization_gates() {
    local remediation_reference="$SKILL_DIR/references/remediation.md"
    local text
    text=$(cat "$remediation_reference")
    if [[ "$text" == *"local edits and local verification"* && \
          "$text" == *"explicitly authorizes hosted feedback"* && \
          "$text" == *"generic fix request stops after local edits and tests"* ]]; then
        pass "remediation.md separates local fixes from explicit hosted mutations"
    else
        fail "remediation.md separates local fixes from explicit hosted mutations" \
            "expected local-only default plus explicit hosted-action gates"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo "============================================"
echo "SKILL.md regression check suite"
echo "============================================"
echo "Target:  ${SKILL_DOCS[*]}"
echo "Fixture: $FIXTURE"
echo ""

test_no_literal_placeholders_in_graphql
test_no_pull_request_review_id_field
test_skill_md_issue_comment_filter
test_legacy_filter_proves_bug_class
test_reference_links_resolve
test_analysis_reference_stays_read_only
test_remediation_authorization_gates

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
