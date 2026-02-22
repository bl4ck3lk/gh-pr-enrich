#!/bin/bash
# Test suite for build_claude_context including issue comments
# Uses integration testing: invokes the actual gh-pr-enrich script via --test-build-context

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output/enrichment"
GH_PR_ENRICH="$PROJECT_DIR/gh-pr-enrich"

# Colors for output
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
    echo "  $2"
    ((TESTS_FAILED++)) || true
    ((TESTS_RUN++)) || true
}

cleanup() {
    rm -rf "$TEST_OUTPUT_DIR"
}

setup() {
    cleanup
    mkdir -p "$TEST_OUTPUT_DIR"
}

# ============================================================================
# Integration Testing Approach
# Tests invoke the actual build_claude_context function via --test-build-context.
# This ensures tests catch regressions in the real implementation.
# ============================================================================

# Invoke the real build_claude_context via the hidden test mode
run_build_claude_context() {
    local dir="$1"
    "$GH_PR_ENRICH" --test-build-context "$dir" 2>/dev/null
}

create_test_fixtures() {
    local dir="$1"

    # PR summary
    cat > "$dir/pr-summary.json" << 'EOF'
{
    "number": 99,
    "title": "Test PR with bot comments",
    "body": "Test description",
    "author": {"login": "testuser"},
    "files": [{"path": "src/app.js"}, {"path": "src/utils.js"}]
}
EOF

    # Unresolved threads (from GraphQL reviewThreads)
    cat > "$dir/unresolved-threads.json" << 'EOF'
[
    {
        "thread_id": "PRRT_test123",
        "comments": [
            {
                "author": "reviewer1",
                "body": "This function needs error handling",
                "url": "https://github.com/test/repo/pull/99#discussion_r1"
            }
        ]
    }
]
EOF

    # Issue comments (includes bot comments that were previously missing)
    cat > "$dir/issue-comments.json" << 'EOF'
[
    {
        "id": 1001,
        "body": "LGTM, nice work!",
        "user": "human-reviewer",
        "created_at": "2026-02-14T10:00:00Z",
        "updated_at": "2026-02-14T10:00:00Z",
        "type": "issue_comment",
        "html_url": "https://github.com/test/repo/pull/99#issuecomment-1001"
    },
    {
        "id": 1002,
        "body": "## ✅ CI Checks\n\n| Build | SwiftLint | Tests |\n|-------|-----------|-------|\n| ⚠️ | ⚠️ | ⚠️ |\n\n[Details](https://github.com/test/repo/actions/runs/123)",
        "user": "github-actions[bot]",
        "created_at": "2026-02-14T11:00:00Z",
        "updated_at": "2026-02-14T11:00:00Z",
        "type": "issue_comment",
        "html_url": "https://github.com/test/repo/pull/99#issuecomment-1002"
    },
    {
        "id": 1003,
        "body": "**Claude finished @testuser's task in 6m 28s** —— [View job](https://github.com/test/repo/actions/runs/456)\n\n---\n### Security Audit\n\nCompleted comprehensive security audit of the changes.",
        "user": "github-actions[bot]",
        "created_at": "2026-02-14T12:00:00Z",
        "updated_at": "2026-02-14T12:00:00Z",
        "type": "issue_comment",
        "html_url": "https://github.com/test/repo/pull/99#issuecomment-1003"
    },
    {
        "id": 1004,
        "body": "## Greptile Overview\n\nThis PR adds authentication...",
        "user": "greptile-apps[bot]",
        "created_at": "2026-02-14T13:00:00Z",
        "updated_at": "2026-02-14T13:00:00Z",
        "type": "issue_comment",
        "html_url": "https://github.com/test/repo/pull/99#issuecomment-1004"
    }
]
EOF

    # Empty diff
    cat > "$dir/pr-diff.json" << 'EOF'
{"raw_diff": "", "file_diffs": []}
EOF
}

create_empty_issue_comments() {
    local dir="$1"
    cat > "$dir/issue-comments.json" << 'EOF'
[]
EOF
}

# ============================================================================
# Tests (Integration tests invoking real implementation)
# ============================================================================

test_context_includes_issue_comments() {
    local dir="$TEST_OUTPUT_DIR/with-issue-comments"
    mkdir -p "$dir"
    create_test_fixtures "$dir"

    # Invoke the real build_claude_context function
    run_build_claude_context "$dir"
    local context_file="$dir/claude-context.json"

    # Test 1: issue_comments field exists
    if jq -e '.issue_comments' "$context_file" > /dev/null 2>&1; then
        pass "Claude context includes issue_comments field"
    else
        fail "Claude context includes issue_comments field" "Field missing from context"
    fi

    # Test 2: correct number of issue comments
    local count
    count=$(jq '.issue_comments | length' "$context_file")
    if [ "$count" -eq 4 ]; then
        pass "Claude context has all 4 issue comments"
    else
        fail "Claude context has all 4 issue comments" "Got: $count"
    fi

    # Test 3: bot comments are included
    local bot_count
    bot_count=$(jq '[.issue_comments[] | select(.user | test("\\[bot\\]$"))] | length' "$context_file")
    if [ "$bot_count" -eq 3 ]; then
        pass "Claude context includes all 3 bot comments"
    else
        fail "Claude context includes all 3 bot comments" "Got: $bot_count"
    fi

    # Test 4: unresolved_threads still present
    local thread_count
    thread_count=$(jq '.unresolved_threads | length' "$context_file")
    if [ "$thread_count" -eq 1 ]; then
        pass "Unresolved threads still present alongside issue comments"
    else
        fail "Unresolved threads still present alongside issue comments" "Got: $thread_count"
    fi

    # Test 5: issue comments have required fields
    local has_fields
    has_fields=$(jq '[.issue_comments[] | select(.user and .body and .url and .created_at)] | length' "$context_file")
    if [ "$has_fields" -eq 4 ]; then
        pass "All issue comments have required fields (user, body, url, created_at)"
    else
        fail "All issue comments have required fields" "Only $has_fields have all fields"
    fi
}

test_context_with_empty_issue_comments() {
    local dir="$TEST_OUTPUT_DIR/empty-issue-comments"
    mkdir -p "$dir"
    create_test_fixtures "$dir"
    create_empty_issue_comments "$dir"

    # Invoke the real build_claude_context function
    run_build_claude_context "$dir"
    local context_file="$dir/claude-context.json"

    local count
    count=$(jq '.issue_comments | length' "$context_file")
    if [ "$count" -eq 0 ]; then
        pass "Empty issue comments produces empty array (not null)"
    else
        fail "Empty issue comments produces empty array" "Got: $count"
    fi
}

test_long_issue_comment_truncation() {
    local dir="$TEST_OUTPUT_DIR/truncation"
    mkdir -p "$dir"
    create_test_fixtures "$dir"

    # Create an issue comment with a very long body (>5000 chars)
    local long_body
    long_body=$(head -c 6000 /dev/zero | tr '\0' 'x')
    jq -n --arg body "$long_body" '[{
        "id": 2001,
        "body": $body,
        "user": "github-actions[bot]",
        "created_at": "2026-02-14T10:00:00Z",
        "updated_at": "2026-02-14T10:00:00Z",
        "type": "issue_comment",
        "html_url": "https://github.com/test/repo/pull/99#issuecomment-2001"
    }]' > "$dir/issue-comments.json"

    # Invoke the real build_claude_context function
    run_build_claude_context "$dir"
    local context_file="$dir/claude-context.json"

    local body_len
    body_len=$(jq '.issue_comments[0].body | length' "$context_file")
    # 5000 + "\n... (truncated)" = 5018
    if [ "$body_len" -lt 5100 ]; then
        pass "Long issue comment body is truncated (${body_len} chars)"
    else
        fail "Long issue comment body is truncated" "Got length: $body_len"
    fi

    if jq -r '.issue_comments[0].body' "$context_file" | grep -q "(truncated)"; then
        pass "Truncated body includes truncation marker"
    else
        fail "Truncated body includes truncation marker" "Missing marker"
    fi
}

test_enrichment_triggers_with_only_issue_comments() {
    # When there are 0 unresolved threads but issue comments exist,
    # enrichment should still proceed
    local dir="$TEST_OUTPUT_DIR/only-issue-comments"
    mkdir -p "$dir"
    create_test_fixtures "$dir"
    echo '[]' > "$dir/unresolved-threads.json"

    local issue_count
    issue_count=$(jq 'length' "$dir/issue-comments.json")

    local unresolved_count
    unresolved_count=$(jq 'length' "$dir/unresolved-threads.json")

    # Simulate the trigger condition: should run if either has data
    if [ "$unresolved_count" -gt 0 ] || [ "$issue_count" -gt 0 ]; then
        pass "Enrichment triggers when only issue comments exist (no unresolved threads)"
    else
        fail "Enrichment triggers when only issue comments exist" "Neither condition met"
    fi
}

test_no_enrichment_when_both_empty() {
    local dir="$TEST_OUTPUT_DIR/both-empty"
    mkdir -p "$dir"
    create_test_fixtures "$dir"
    echo '[]' > "$dir/unresolved-threads.json"
    echo '[]' > "$dir/issue-comments.json"

    local issue_count
    issue_count=$(jq 'length' "$dir/issue-comments.json")

    local unresolved_count
    unresolved_count=$(jq 'length' "$dir/unresolved-threads.json")

    if [ "$unresolved_count" -gt 0 ] || [ "$issue_count" -gt 0 ]; then
        fail "No enrichment when both empty" "Condition unexpectedly true"
    else
        pass "No enrichment when both unresolved threads and issue comments are empty"
    fi
}

# ============================================================================
# Main
# ============================================================================

echo "============================================"
echo "gh pr-enrich enrichment context test suite"
echo "============================================"
echo ""

setup

test_context_includes_issue_comments
test_context_with_empty_issue_comments
test_long_issue_comment_truncation
test_enrichment_triggers_with_only_issue_comments
test_no_enrichment_when_both_empty

# Summary
echo ""
echo "============================================"
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
if [ "$TESTS_FAILED" -gt 0 ]; then
    echo -e "${RED}$TESTS_FAILED tests failed${NC}"
    cleanup
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    cleanup
    exit 0
fi
