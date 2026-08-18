#!/bin/bash
# Tests for how the analyzer is invoked and what it is allowed to do.
#
# Covers:
#   - the analyzer can read the repository (Read/Grep/Glob) so it verifies
#     claims against code instead of paraphrasing the diff
#   - the model is configurable rather than hardcoded
#   - the timeout matches the work being asked for
#   - analyzer stderr is captured to a log, not discarded
#   - the optional semgrep pre-pass produces normalized findings and degrades
#     cleanly when semgrep is absent

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GH_PR_ENRICH="$PROJECT_DIR/gh-pr-enrich"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output/invocation"
STUB_DIR="$TEST_OUTPUT_DIR/stubs"
ARG_LOG="$TEST_OUTPUT_DIR/claude-args.txt"

# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

cleanup() { rm -rf "$TEST_OUTPUT_DIR"; }
trap cleanup EXIT
cleanup
mkdir -p "$TEST_OUTPUT_DIR" "$STUB_DIR"

suite_start "gh pr-enrich analyzer invocation suite"

# --- stubs ------------------------------------------------------------------
cat > "$STUB_DIR/claude" << 'STUB'
#!/bin/bash
# Records the argv it was invoked with, drains stdin, emits a valid response.
printf '%s\n' "$@" > "$CLAUDE_ARG_LOG"
cat > /dev/null
echo "stub claude stderr line" >&2
echo '{"structured_output": {"issue_categories": [], "category_coverage": [], "disputed_comments": [], "systemic_issues": [], "adjacent_problems": [], "task_list": [], "process_improvements": [], "pr_template_suggestions": []}}'
STUB
chmod +x "$STUB_DIR/claude"

cat > "$STUB_DIR/timeout" << 'STUB'
#!/bin/bash
# Drops timeout's own flags and duration, records the duration, execs the rest.
DURATION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --signal=*|--foreground|-k) shift ;;
        *) DURATION="$1"; shift; break ;;
    esac
done
printf '%s' "$DURATION" > "$CLAUDE_TIMEOUT_LOG"
exec "$@"
STUB
chmod +x "$STUB_DIR/timeout"

cat > "$STUB_DIR/semgrep" << 'STUB'
#!/bin/bash
cat << 'JSON'
{"results": [
  {"check_id": "javascript.lang.security.audit.unsafe-exec",
   "path": "src/retry.js",
   "start": {"line": 12},
   "extra": {"severity": "ERROR", "message": "Detected unsafe exec", "metadata": {"cwe": ["CWE-78"]}}}
], "errors": []}
JSON
STUB
chmod +x "$STUB_DIR/semgrep"

CONTEXT="$TEST_OUTPUT_DIR/claude-context.json"
echo '{"pr": {"title": "t"}, "unresolved_threads": [], "issue_comments": []}' > "$CONTEXT"
RESPONSE="$TEST_OUTPUT_DIR/response.json"

run_analysis() {
    env CLAUDE_ARG_LOG="$ARG_LOG" CLAUDE_TIMEOUT_LOG="$TEST_OUTPUT_DIR/timeout.txt" \
        PATH="$STUB_DIR:$PATH" "$@" \
        "$GH_PR_ENRICH" --test-call run_claude_analysis "$CONTEXT" "$RESPONSE" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Code access
# ---------------------------------------------------------------------------
run_analysis
ARGS=$(cat "$ARG_LOG" 2>/dev/null || echo "")

assert_contains "$ARGS" "--allowedTools" "analyzer is granted tools by default"
assert_contains "$ARGS" "Read" "analyzer may read files"
assert_contains "$ARGS" "Grep" "analyzer may grep the repository"
assert_contains "$ARGS" "Glob" "analyzer may glob the repository"
assert_not_contains "$ARGS" "Bash" "analyzer is not granted Bash"
assert_not_contains "$ARGS" "Write" "analyzer is not granted Write"
assert_not_contains "$ARGS" "Edit" "analyzer is not granted Edit"
assert_contains "$ARGS" "--json-schema" "analyzer is given the structured-output schema"

# Opt-out for sandboxed environments
run_analysis GH_PR_ENRICH_CODE_ACCESS=false
ARGS_NO_CODE=$(cat "$ARG_LOG" 2>/dev/null || echo "")
assert_not_contains "$ARGS_NO_CODE" "--allowedTools" "code access can be disabled"

# ---------------------------------------------------------------------------
# Model selection
# ---------------------------------------------------------------------------
run_analysis
assert_contains "$(cat "$ARG_LOG")" "sonnet" "default model is sonnet"

run_analysis GH_PR_ENRICH_MODEL=opus
assert_contains "$(cat "$ARG_LOG")" "opus" "model is overridable via GH_PR_ENRICH_MODEL"

# ---------------------------------------------------------------------------
# Timeout
# ---------------------------------------------------------------------------
run_analysis
DEFAULT_TIMEOUT=$(cat "$TEST_OUTPUT_DIR/timeout.txt" 2>/dev/null || echo "0")
if [ "${DEFAULT_TIMEOUT:-0}" -ge 600 ]; then
    pass "default timeout allows for code-reading analysis (${DEFAULT_TIMEOUT}s)"
else
    fail "default timeout allows for code-reading analysis" "got: ${DEFAULT_TIMEOUT}s"
fi

run_analysis CLAUDE_TIMEOUT=42
assert_eq "42" "$(cat "$TEST_OUTPUT_DIR/timeout.txt" 2>/dev/null || echo "")" \
    "CLAUDE_TIMEOUT still overrides the default"

# ---------------------------------------------------------------------------
# Analyzer stderr is kept
# ---------------------------------------------------------------------------
run_analysis
STDERR_LOG="$TEST_OUTPUT_DIR/claude-stderr.log"
if [ -f "$STDERR_LOG" ]; then
    assert_contains "$(cat "$STDERR_LOG")" "stub claude stderr line" \
        "analyzer stderr is captured to a log next to the response"
else
    fail "analyzer stderr is captured to a log next to the response" "no $STDERR_LOG written"
fi
assert_not_contains "$(grep -c '2>/dev/null' "$GH_PR_ENRICH" >/dev/null && sed -n '/^run_claude_analysis/,/^}/p' "$GH_PR_ENRICH")" \
    "2>/dev/null" "run_claude_analysis no longer discards stderr"

# ---------------------------------------------------------------------------
# SAST pre-pass
# ---------------------------------------------------------------------------
# The collector scans changed files that exist in the working tree, so the
# fixture is a small workspace rather than a bare report directory.
WORKSPACE="$TEST_OUTPUT_DIR/workspace"
SAST_DIR="$WORKSPACE/reports"
mkdir -p "$SAST_DIR" "$WORKSPACE/src"
echo "const x = 1;" > "$WORKSPACE/src/retry.js"
cat > "$SAST_DIR/pr-summary.json" << 'EOF'
{"number": 1, "title": "t", "body": "", "author": {"login": "u"},
 "files": [{"path": "src/retry.js"}, {"path": "src/deleted-by-this-pr.js"}]}
EOF

(cd "$WORKSPACE" && PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call collect_sast_findings "reports" >/dev/null 2>&1) || true
SAST_FILE="$SAST_DIR/sast-findings.json"

assert_jq_eq "$SAST_FILE" 'length' "1" "semgrep findings are collected"
assert_jq "$SAST_FILE" '.[0].path == "src/retry.js"' "finding carries its path"
assert_jq "$SAST_FILE" '.[0].line == 12' "finding carries its line"
assert_jq "$SAST_FILE" '.[0].severity == "ERROR"' "finding carries its severity"
assert_jq "$SAST_FILE" '.[0].check_id | contains("unsafe-exec")' "finding carries its rule id"
assert_jq "$SAST_FILE" '.[0].message | contains("unsafe exec")' "finding carries its message"

# Missing semgrep must warn and continue, never abort the run.
EMPTY_STUBS="$TEST_OUTPUT_DIR/empty-stubs"
mkdir -p "$EMPTY_STUBS"
SAST_DIR2="$TEST_OUTPUT_DIR/sast-nosemgrep"
mkdir -p "$SAST_DIR2"
cp "$SAST_DIR/pr-summary.json" "$SAST_DIR2/pr-summary.json"

rc=0
out=$(PATH="$EMPTY_STUBS:/usr/bin:/bin" "$GH_PR_ENRICH" --test-call collect_sast_findings "$SAST_DIR2" 2>&1) || rc=$?

assert_true "$rc" "missing semgrep does not fail the run"
assert_contains "$out" "semgrep" "missing semgrep is reported to the user"
assert_jq_eq "$SAST_DIR2/sast-findings.json" 'length' "0" "missing semgrep yields an empty finding set"

suite_end
