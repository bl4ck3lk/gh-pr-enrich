#!/bin/bash
# Test suite for gh pr-enrich retrospective subcommand

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output/retrospective"
SOURCE_FIXTURES_DIR="$SCRIPT_DIR/fixtures"
FIXTURES_DIR="$TEST_OUTPUT_DIR/fixtures"
GH_PR_ENRICH="$PROJECT_DIR/gh-pr-enrich"

# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

cleanup() {
    rm -rf "$TEST_OUTPUT_DIR"
}

setup() {
    cleanup
    mkdir -p "$TEST_OUTPUT_DIR"
    cp -R "$SOURCE_FIXTURES_DIR" "$FIXTURES_DIR"
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

    if echo "$output" | grep -q "No PR reports found with structured analysis"; then
        pass "Error when no structured analysis files"
    else
        fail "Error when no structured analysis files" "Got: $output"
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

test_hotspots_group_by_taxonomy() {
    # pr-1 and pr-2 report error_handling findings under different names. Grouping
    # by the free-text name would report two hotspots of one; grouping by the
    # taxonomy category reports one hotspot spanning two PRs.
    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$FIXTURES_DIR" \
        --output-dir "$TEST_OUTPUT_DIR/hotspots" --json 2>/dev/null)

    local hotspot_prs
    hotspot_prs=$(echo "$output" | jq '[.hotspots[]? // empty | select(.category == "error_handling") | .prs | length] | first // 0')

    if [ "${hotspot_prs:-0}" -ge 2 ]; then
        pass "hotspots group by taxonomy category across PRs (error_handling spans $hotspot_prs PRs)"
    else
        fail "hotspots group by taxonomy category across PRs" \
            "error_handling hotspot covered ${hotspot_prs:-0} PR(s); categories seen: $(echo "$output" | jq -c '[.hotspots[]?.category]')"
    fi

    if echo "$output" | jq -e '[.hotspots[]? | select(.category == "Error Handling")] | length == 0' > /dev/null 2>&1; then
        pass "hotspots no longer keyed by free-text finding name"
    else
        fail "hotspots no longer keyed by free-text finding name" "found a name-keyed hotspot"
    fi
}

test_legacy_reports_are_reported_not_mixed_in() {
    # Reports written before the taxonomy existed have no .category. Folding them
    # into an "uncategorized" hotspot produces a confident, useless answer:
    # "Have I checked uncategorized for similar issues?". They must be named and
    # excluded instead, so the user knows to re-enrich them.
    local legacy_root="$TEST_OUTPUT_DIR/legacy/pr-77"
    mkdir -p "$legacy_root"
    cat > "$legacy_root/pr-summary.json" << 'EOF'
{"number": 77, "title": "Legacy PR", "author": {"login": "alice"}, "createdAt": "2026-01-01T00:00:00Z"}
EOF
    cat > "$legacy_root/claude-analysis.json" << 'EOF'
{
  "issue_categories": [
    {"name": "ARG_MAX overflow risk", "severity": "high",
     "description": "Old-format finding with no category field", "thread_ids": ["PRRT_old"]}
  ],
  "systemic_issues": [],
  "adjacent_problems": [],
  "task_list": [],
  "process_improvements": [],
  "pr_template_suggestions": []
}
EOF

    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$TEST_OUTPUT_DIR/legacy" \
        --output-dir "$TEST_OUTPUT_DIR/legacy-out" --min-prs 1 2>&1) || true

    if echo "$output" | grep -qi "re-run\|re-enrich\|older format\|pre-2"; then
        pass "legacy reports are called out with what to do about them"
    else
        fail "legacy reports are called out with what to do about them" \
            "got: $(echo "$output" | tail -5 | tr '\n' '|')"
    fi

    if echo "$output" | grep -q "pr-77"; then
        pass "the specific legacy report is named"
    else
        fail "the specific legacy report is named" "expected pr-77 in the output"
    fi

    local hotspots
    hotspots=$(jq -c '[.hotspots[]?.category]' "$TEST_OUTPUT_DIR/legacy-out/retrospective-data.json" 2>/dev/null || echo "[]")
    if echo "$hotspots" | grep -q "uncategorized"; then
        fail "legacy findings do not become an 'uncategorized' hotspot" "hotspots: $hotspots"
    else
        pass "legacy findings do not become an 'uncategorized' hotspot"
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

test_provider_neutral_analysis_is_discovered() {
    local report_root="$TEST_OUTPUT_DIR/provider-neutral/pr-1"
    local output_root="$TEST_OUTPUT_DIR/provider-neutral-out"
    local fingerprint
    mkdir -p "$report_root"
    cp "$FIXTURES_DIR/pr-1/pr-summary.json" "$report_root/pr-summary.json"
    jq '.headRefOid = "fixture-head"' "$report_root/pr-summary.json" \
        > "$report_root/pr-summary.tmp.json"
    mv "$report_root/pr-summary.tmp.json" "$report_root/pr-summary.json"
    jq -n '{pr:{repository:"o/r",number:1},
        coverage:{code_access:{pr_head_sha:"fixture-head"}}}' \
        > "$report_root/analysis-context.tmp.json"
    fingerprint=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
        "$report_root/analysis-context.tmp.json")
    jq --arg fingerprint "$fingerprint" '.coverage.context_fingerprint = $fingerprint' \
        "$report_root/analysis-context.tmp.json" > "$report_root/analysis-context.json"
    jq --arg fingerprint "$fingerprint" '. + {_metadata:{
        provider:"codex", repository:"o/r", pr_number:1,
        pr_head_sha:"fixture-head", context_fingerprint:$fingerprint,
        generated_at:"2026-01-01T00:00:00Z",
        analyzers:[{provider:"codex",role:"orchestrator"}]
    }}' "$FIXTURES_DIR/pr-1/claude-analysis.json" > "$report_root/analysis.json"

    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$TEST_OUTPUT_DIR/provider-neutral" \
        --output-dir "$output_root" --min-prs 1 2>&1)

    if echo "$output" | grep -q "Found 1 PR reports with structured analysis"; then
        pass "retrospective discovers provider-neutral analysis.json"
    else
        fail "retrospective discovers provider-neutral analysis.json" "Got: $output"
    fi

    if [ "$(jq '.summary.overview.total_prs_analyzed' "$output_root/retrospective-data.json")" = "1" ]; then
        pass "provider-neutral report is included in aggregation"
    else
        fail "provider-neutral report is included in aggregation"
    fi
}

test_current_rejected_source_is_not_aggregated() {
    local report_root="$TEST_OUTPUT_DIR/current-rejected/pr-91"
    local output_root="$TEST_OUTPUT_DIR/current-rejected-out"
    mkdir -p "$report_root"
    cat > "$report_root/pr-summary.json" << 'EOF'
{"number":91,"title":"Current rejected source","author":{"login":"u"},"createdAt":"2026-01-01T00:00:00Z"}
EOF
    jq -n '{issue_categories:[],category_coverage:[],disputed_comments:[],
        systemic_issues:[],adjacent_problems:[],task_list:[],process_improvements:[],
        pr_template_suggestions:[],_metadata:{provider:"claude",pr_head_sha:"head",
        context_fingerprint:"sha256:fixture"}}' > "$report_root/claude-analysis.json"

    local output
    output=$("$GH_PR_ENRICH" retrospective --reports-dir "$TEST_OUTPUT_DIR/current-rejected" \
        --output-dir "$output_root" --min-prs 1 2>&1 || true)
    if echo "$output" | grep -q "Found 0 PR reports with structured analysis"; then
        pass "retrospective excludes a current Claude source that was not selected"
    else
        fail "retrospective excludes a current Claude source that was not selected" "Got: $output"
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
test_hotspots_group_by_taxonomy
test_legacy_reports_are_reported_not_mixed_in
test_improvement_tracking
test_provider_neutral_analysis_is_discovered
test_current_rejected_source_is_not_aggregated

# Summary
trap cleanup EXIT
suite_end
