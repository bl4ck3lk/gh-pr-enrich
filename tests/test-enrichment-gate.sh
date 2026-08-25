#!/bin/bash
# End-to-end test of the enrichment gate, driven through the real script.
#
# The previous version of these checks re-implemented the trigger condition
# inside the test, so the shipped gate could have been inverted and they would
# still have passed. This runs `gh-pr-enrich <N> --enrich` against stubbed `gh`
# and `claude` binaries and asserts on what the script actually did.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GH_PR_ENRICH="$PROJECT_DIR/gh-pr-enrich"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output/enrichment-gate"
STUB_DIR="$TEST_OUTPUT_DIR/stubs"

# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

cleanup() { rm -rf "$TEST_OUTPUT_DIR"; }
trap cleanup EXIT
cleanup
mkdir -p "$STUB_DIR"

suite_start "gh pr-enrich enrichment gate suite"

# --- stubs ------------------------------------------------------------------
# gh reads its canned responses from $FIXTURE_DIR, so each scenario supplies its
# own threads and comments without changing the stub.
cat > "$STUB_DIR/gh" << 'STUB'
#!/bin/bash
case "$1 $2" in
    "repo view")
        case "$*" in
            *nameWithOwner,visibility*) printf '{"nameWithOwner":"o/r","visibility":"%s"}\n' "${REPO_VISIBILITY:-PUBLIC}" ;;
            *visibility*) echo "${REPO_VISIBILITY:-PUBLIC}" ;;
            *) echo "o/r" ;;
        esac
        exit 0
        ;;
    "pr view")     cat "$FIXTURE_DIR/pr-summary.json"; exit 0 ;;
    "pr checks")   echo '[]'; exit 0 ;;
    "pr diff")     echo ""; exit 0 ;;
esac
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    case "$*" in
        *closingIssuesReferences*) echo '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"nodes":[]}}}}}' ;;
        *) cat "$FIXTURE_DIR/threads.json" ;;
    esac
    exit 0
fi
if [ "$1" = "api" ]; then
    case "$*" in
        *issues/*/comments*) cat "$FIXTURE_DIR/issue-comments.json" ;;
        *) echo '[]' ;;
    esac
    exit 0
fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"

cat > "$STUB_DIR/claude" << 'STUB'
#!/bin/bash
# Records that it ran, drains stdin, returns a minimal valid analysis.
echo "invoked" >> "$CLAUDE_INVOKED_LOG"
cat > /dev/null
jq -nc '
  ["logic_error","boundary_condition","concurrency","error_handling","resource_lifecycle","security","secrets_exposure","data_integrity","api_contract","performance","test_gap","observability","maintainability","documentation","build_ci","dependency_risk"] as $categories
  | {structured_output:{issue_categories:[],
      category_coverage:[$categories[] | {category:., verdict:"reviewed_none_found", note:"fixture"}],
      disputed_comments:[],systemic_issues:[],adjacent_problems:[],task_list:[],
      process_improvements:[],pr_template_suggestions:[]}}'
STUB
chmod +x "$STUB_DIR/claude"

cat > "$STUB_DIR/timeout" << 'STUB'
#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in --signal=*|--foreground|-k) shift ;; *) shift; break ;; esac
done
exec "$@"
STUB
chmod +x "$STUB_DIR/timeout"

THREAD_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRRT_open","isResolved":false,"isOutdated":false,"path":"a.js","line":1,
   "comments":{"nodes":[{"id":"c","databaseId":1,"body":"needs a guard","author":{"login":"rev"},"createdAt":"2026-01-01T00:00:00Z","url":"https://github.com/o/r/pull/1#discussion_r1"}]}}
]}}}}}'
NO_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
# Raw GitHub REST shape: the script maps .user.login itself.
ONE_COMMENT='[{"id":1,"body":"CI failed on lint","user":{"login":"github-actions[bot]"},"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","html_url":"https://github.com/o/r/pull/1#issuecomment-1"}]'

# Runs the real script end to end for one scenario.
# $1 = scenario name, $2 = threads json, $3 = issue-comments json
run_scenario() {
    local name="$1" threads="$2" comments="$3"
    local fixtures="$TEST_OUTPUT_DIR/$name/fixtures"
    local out="$TEST_OUTPUT_DIR/$name/report"
    mkdir -p "$fixtures" "$out"

    printf '%s' "$threads" > "$fixtures/threads.json"
    printf '%s' "$comments" > "$fixtures/issue-comments.json"
    cat > "$fixtures/pr-summary.json" << 'EOF'
{"number": 1, "title": "t", "body": "b", "author": {"login": "u"}, "state": "OPEN",
 "url": "https://github.com/o/r/pull/1", "createdAt": "2026-01-01T00:00:00Z",
 "updatedAt": "2026-01-01T00:00:00Z", "mergeable": "MERGEABLE", "isDraft": false,
 "headRefOid": "abc123",
 "additions": 1, "deletions": 0, "changedFiles": 1, "files": [{"path": "a.js", "additions": 1, "deletions": 0}],
 "commits": [], "labels": [], "assignees": [], "reviews": []}
EOF

    env FIXTURE_DIR="$fixtures" CLAUDE_INVOKED_LOG="$TEST_OUTPUT_DIR/$name/claude-invoked.txt" \
        PATH="$STUB_DIR:$PATH" \
        "$GH_PR_ENRICH" 1 --enrich --output-dir "$out" 2>&1 || true
}

claude_ran() {
    [ -s "$TEST_OUTPUT_DIR/$1/claude-invoked.txt" ] && echo yes || echo no
}

# ---------------------------------------------------------------------------
# Unresolved thread, no issue comments -> analysis runs
# ---------------------------------------------------------------------------
OUT=$(run_scenario "threads-only" "$THREAD_JSON" '[]')
assert_eq "yes" "$(claude_ran threads-only)" "an unresolved thread triggers the analysis"
assert_contains "$OUT" "Found 1 unresolved thread" "the script reports what it found"
assert_jq "$TEST_OUTPUT_DIR/threads-only/report/claude-analysis.json" '.issue_categories != null' \
    "the analysis result is written"
assert_jq "$TEST_OUTPUT_DIR/threads-only/report/analysis.json" '._metadata.provider == "claude"' \
    "the provider-neutral analysis records Claude attribution"
assert_jq "$TEST_OUTPUT_DIR/threads-only/report/analysis.json" \
    '._metadata.pr_head_sha != null and ._metadata.generated_at != null' \
    "the provider-neutral analysis records snapshot provenance"
assert_jq "$TEST_OUTPUT_DIR/threads-only/report/analysis-context.json" '.coverage != null' \
    "the provider-neutral analysis context is written"

# ---------------------------------------------------------------------------
# Issue comment only, no threads -> analysis still runs (bot/CI reports matter)
# ---------------------------------------------------------------------------
OUT=$(run_scenario "comments-only" "$NO_THREADS" "$ONE_COMMENT")
assert_eq "yes" "$(claude_ran comments-only)" "an issue comment alone triggers the analysis"
assert_contains "$OUT" "1 issue comment" "the script reports the issue comment it found"

# ---------------------------------------------------------------------------
# Nothing to analyze -> analysis is skipped, and the run still succeeds
# ---------------------------------------------------------------------------
OUT=$(run_scenario "both-empty" "$NO_THREADS" '[]')
assert_eq "no" "$(claude_ran both-empty)" "no analysis runs when there is nothing to analyze"
assert_contains "$OUT" "Skipping Claude analysis" "the skip is reported"
assert_contains "$OUT" "Report generated successfully" "the run still completes"

# ---------------------------------------------------------------------------
# An incomplete category sweep is reported
#
# The prompt demands a verdict for all 16 categories, but a JSON schema cannot
# require "all of them present". An analysis that skips categories while looking
# complete is the exact failure the coverage section exists to prevent.
# ---------------------------------------------------------------------------
cat > "$STUB_DIR/claude" << 'STUB'
#!/bin/bash
echo "invoked" >> "$CLAUDE_INVOKED_LOG"
cat > /dev/null
echo '{"structured_output": {"issue_categories": [], "category_coverage": [{"category": "security", "verdict": "reviewed_none_found", "note": "n"}], "disputed_comments": [], "systemic_issues": [], "adjacent_problems": [], "task_list": [], "process_improvements": [], "pr_template_suggestions": []}}'
STUB
chmod +x "$STUB_DIR/claude"

OUT=$(run_scenario "partial-coverage" "$THREAD_JSON" '[]')
assert_contains "$OUT" "Category coverage is incomplete" "an incomplete sweep is reported"
assert_contains "$OUT" "1 of 16" "the report says how many categories were swept"
assert_contains "$OUT" "logic_error" "the unswept categories are named"
assert_true "$([ ! -e "$TEST_OUTPUT_DIR/partial-coverage/report/analysis.json" ] && echo 0 || echo 1)" \
    "an incomplete category sweep is not promoted as selected analysis"

# ---------------------------------------------------------------------------
# Structured output missing entirely (clean exit, unusable result)
# ---------------------------------------------------------------------------
cat > "$STUB_DIR/claude" << 'STUB'
#!/bin/bash
echo "invoked" >> "$CLAUDE_INVOKED_LOG"
cat > /dev/null
echo '{"is_error": false, "result": "I could not produce structured output."}'
STUB
chmod +x "$STUB_DIR/claude"

OUT=$(run_scenario "no-structured-output" "$THREAD_JSON" '[]')
assert_contains "$OUT" "no structured output" "a missing analysis is called out, not passed off as empty"
assert_contains "$OUT" "claude-stderr.log" "the user is pointed at the analyzer log"
assert_true "$([ ! -e "$TEST_OUTPUT_DIR/no-structured-output/report/claude-analysis.json" ] && echo 0 || echo 1)" \
    "an analyzer envelope is not published as Claude analysis"
assert_true "$([ ! -e "$TEST_OUTPUT_DIR/no-structured-output/report/analysis.json" ] && echo 0 || echo 1)" \
    "an unusable analyzer response is not published as selected analysis"

suite_end
