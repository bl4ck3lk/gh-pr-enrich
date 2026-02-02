#!/bin/bash
# Test suite for gh pr-enrich retrospective subcommand

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output"
GH_PR_ENRICH="$PROJECT_DIR/gh-pr-enrich"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
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

skip() {
    echo -e "${YELLOW}○${NC} $1 (skipped)"
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
# Test Cases
# ============================================================================

test_help_output() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --help 2>&1)

    if echo "$output" | grep -q "Usage: gh pr-enrich retrospective"; then
        pass "Help shows usage"
    else
        fail "Help shows usage" "Missing usage line"
    fi

    if echo "$output" | grep -q "\-\-since"; then
        pass "Help shows --since option"
    else
        fail "Help shows --since option" "Missing --since"
    fi

    if echo "$output" | grep -q "\-\-author"; then
        pass "Help shows --author option"
    else
        fail "Help shows --author option" "Missing --author"
    fi

    if echo "$output" | grep -q "\-\-enrich"; then
        pass "Help shows --enrich option"
    else
        fail "Help shows --enrich option" "Missing --enrich"
    fi

    if echo "$output" | grep -q "\-\-format"; then
        pass "Help shows --format option"
    else
        fail "Help shows --format option" "Missing --format"
    fi
}

test_no_reports_directory() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir /nonexistent 2>&1) || true

    if echo "$output" | grep -q "Reports directory not found"; then
        pass "Error when reports directory missing"
    else
        fail "Error when reports directory missing" "Got: $output"
    fi
}

test_no_analysis_files() {
    local empty_dir="$TEST_OUTPUT_DIR/empty-reports/pr-1"
    mkdir -p "$empty_dir"
    touch "$empty_dir/pr-summary.json"

    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$TEST_OUTPUT_DIR/empty-reports" 2>&1) || true

    if echo "$output" | grep -q "No PR reports found with Claude analysis"; then
        pass "Error when no claude-analysis.json files"
    else
        fail "Error when no claude-analysis.json files" "Got: $output"
    fi
}

test_minimum_prs_warning() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --min-prs 10 2>&1)

    if echo "$output" | grep -q "Warning: Found .* PR(s)"; then
        pass "Warning when below minimum PRs"
    else
        fail "Warning when below minimum PRs" "Got: $output"
    fi
}

test_basic_run() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 2>&1)

    if echo "$output" | grep -q "Retrospective analysis complete"; then
        pass "Basic run completes successfully"
    else
        fail "Basic run completes successfully" "Got: $output"
    fi

    # Check output files exist
    if [ -f "$TEST_OUTPUT_DIR/retro/retrospective-data.json" ]; then
        pass "Creates retrospective-data.json"
    else
        fail "Creates retrospective-data.json" "File not found"
    fi

    if [ -f "$TEST_OUTPUT_DIR/retro/retrospective-report.md" ]; then
        pass "Creates retrospective-report.md"
    else
        fail "Creates retrospective-report.md" "File not found"
    fi

    if [ -f "$TEST_OUTPUT_DIR/retro/cross-pr-patterns.json" ]; then
        pass "Creates cross-pr-patterns.json"
    else
        fail "Creates cross-pr-patterns.json" "File not found"
    fi
}

test_aggregation() {
    "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 >/dev/null 2>&1

    local total_prs
    total_prs=$(jq '.summary.overview.total_prs_analyzed' "$TEST_OUTPUT_DIR/retro/retrospective-data.json")

    if [ "$total_prs" -eq 3 ]; then
        pass "Aggregates correct number of PRs (3)"
    else
        fail "Aggregates correct number of PRs (3)" "Got: $total_prs"
    fi
}

test_pattern_detection() {
    "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 >/dev/null 2>&1

    # The "Inconsistent error handling" pattern appears in all 3 PRs
    local pattern_occurrences
    pattern_occurrences=$(jq '[.cross_pr_patterns[] | select(.pattern | test("error handling"; "i"))] | .[0].occurrences' "$TEST_OUTPUT_DIR/retro/retrospective-data.json")

    if [ "$pattern_occurrences" -eq 3 ]; then
        pass "Detects recurring pattern across 3 PRs"
    else
        fail "Detects recurring pattern across 3 PRs" "Got occurrences: $pattern_occurrences"
    fi
}

test_author_filter() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro-alice" --author alice --min-prs 1 2>&1)

    if echo "$output" | grep -q "Found 2 PR reports"; then
        pass "Author filter finds correct PRs (alice=2)"
    else
        fail "Author filter finds correct PRs (alice=2)" "Got: $output"
    fi
}

test_json_output() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 --json 2>/dev/null)

    if echo "$output" | jq -e '.metadata' >/dev/null 2>&1; then
        pass "JSON output is valid JSON with metadata"
    else
        fail "JSON output is valid JSON with metadata" "Invalid JSON"
    fi

    if echo "$output" | jq -e '.summary.overview' >/dev/null 2>&1; then
        pass "JSON output contains summary.overview"
    else
        fail "JSON output contains summary.overview" "Missing summary.overview"
    fi
}

test_markdown_output() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 --markdown 2>/dev/null)

    if echo "$output" | grep -q "# Team Retrospective Report"; then
        pass "Markdown output has correct header"
    else
        fail "Markdown output has correct header" "Missing header"
    fi

    if echo "$output" | grep -q "Cross-PR Systemic Patterns"; then
        pass "Markdown output has patterns section"
    else
        fail "Markdown output has patterns section" "Missing patterns section"
    fi
}

test_format_claude_md() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 --format claude-md 2>/dev/null)

    if echo "$output" | grep -q "Lessons Learned from PR Reviews"; then
        pass "--format claude-md generates CLAUDE.md section"
    else
        fail "--format claude-md generates CLAUDE.md section" "Missing expected content"
    fi
}

test_format_checklist() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 --format checklist 2>/dev/null)

    if echo "$output" | grep -q "Implementation Checklist"; then
        pass "--format checklist generates checklist"
    else
        fail "--format checklist generates checklist" "Missing expected content"
    fi

    if echo "$output" | grep -q "\- \[ \]"; then
        pass "--format checklist contains checkboxes"
    else
        fail "--format checklist contains checkboxes" "Missing checkboxes"
    fi
}

test_format_pr_template() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 --format pr-template 2>/dev/null)

    if echo "$output" | grep -q "PR Review Checklist"; then
        pass "--format pr-template generates PR template"
    else
        fail "--format pr-template generates PR template" "Missing expected content"
    fi
}

test_invalid_format() {
    local output
    output=$("$GH_PR_ENRICH" retrospective --format invalid 2>&1) || true

    if echo "$output" | grep -q "must be one of"; then
        pass "Invalid --format shows error"
    else
        fail "Invalid --format shows error" "Got: $output"
    fi
}

test_guiding_questions() {
    "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 >/dev/null 2>&1

    local has_questions
    has_questions=$(jq '.guiding_questions.before_implementation | length > 0' "$TEST_OUTPUT_DIR/retro/retrospective-data.json")

    if [ "$has_questions" = "true" ]; then
        pass "Generates guiding questions"
    else
        fail "Generates guiding questions" "No questions generated"
    fi
}

test_improvement_tracking() {
    "$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" --output-dir "$TEST_OUTPUT_DIR/retro" --min-prs 1 >/dev/null 2>&1

    local suggestions
    suggestions=$(jq '.improvement_tracking.suggestions_made' "$TEST_OUTPUT_DIR/retro/retrospective-data.json")

    if [ "$suggestions" -ge 1 ]; then
        pass "Tracks improvement suggestions"
    else
        fail "Tracks improvement suggestions" "Got: $suggestions"
    fi
}

# ============================================================================
# Main
# ============================================================================

echo "============================================"
echo "gh pr-enrich retrospective test suite"
echo "============================================"
echo ""

setup

# Run tests
test_help_output
test_no_reports_directory
test_no_analysis_files
test_minimum_prs_warning
test_basic_run
test_aggregation
test_pattern_detection
test_author_filter
test_json_output
test_markdown_output
test_format_claude_md
test_format_checklist
test_format_pr_template
test_invalid_format
test_guiding_questions
test_improvement_tracking

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
