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
# The context records the PR head; the analyzer re-checks it against the working
# tree before granting tools, so the fixture claims the revision under test.
HEAD_SHA=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "")
jq -n --arg sha "$HEAD_SHA" '{
    pr: {title: "t"}, unresolved_threads: [], issue_comments: [],
    coverage: {code_access: {pr_head_sha: $sha}}
}' > "$CONTEXT"
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
# Static guard: the analyzer's own output must go to the log, never to /dev/null.
INVOKER_FN=$(sed -n '/^invoke_claude() {/,/^}/p' "$GH_PR_ENRICH")
assert_contains "$INVOKER_FN" '2> "$stderr_log"' "analyzer stderr is redirected to the log file"
assert_not_contains "$INVOKER_FN" '> "$output_file" 2>/dev/null' \
    "analyzer output redirection no longer discards stderr"

# One invoker, two callers: the PR analysis and the retrospective must not grow
# separate copies of the CLI invocation, or a fix to one will miss the other.
# Count any invocation of the claude binary, not just the `claude --print` spelling:
# a second call site written differently would otherwise slip past this guard.
claude_calls=$(grep -v '^[[:space:]]*#' "$GH_PR_ENRICH" \
    | grep -E '(^|[|&;( ])claude([[:space:]]|$)' \
    | grep -vE 'command -v claude|--argjson claude|Optional:' \
    | wc -l | tr -d ' ')
assert_eq "1" "$claude_calls" "the Claude CLI is invoked from exactly one place"
assert_contains "$(sed -n '/^run_claude_analysis() {/,/^}/p' "$GH_PR_ENRICH")" 'invoke_claude' \
    "PR analysis delegates to the shared invoker"
assert_contains "$(sed -n '/run_retrospective_claude_analysis() {/,/^    }/p' "$GH_PR_ENRICH")" 'invoke_claude' \
    "retrospective analysis delegates to the shared invoker"

# ---------------------------------------------------------------------------
# Code access is only meaningful when the working tree holds the PR's code
#
# Reading `main` while analyzing PR #123 produces confident verdicts and
# file:line anchors for code the PR does not contain. The revision must be
# checked, not assumed.
# ---------------------------------------------------------------------------
revision_state() {
    # resolve_code_access PR_HEAD_SHA -> prints "enabled"/"disabled" plus reason
    env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call resolve_code_access "$1" 2>&1 || true
}

LOCAL_HEAD=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo "nogit")

MATCHED=$(revision_state "$LOCAL_HEAD")
assert_contains "$MATCHED" "enabled" "code access is enabled when the tree is at the PR head"

MISMATCHED=$(revision_state "0000000000000000000000000000000000000000")
assert_contains "$MISMATCHED" "disabled" "code access is disabled when the tree is not at the PR head"
assert_contains "$MISMATCHED" "gh pr checkout" "the user is told how to align the working tree"

FORCED=$(env GH_PR_ENRICH_CODE_ACCESS=true PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call resolve_code_access "0000000000000000000000000000000000000000" 2>&1 || true)
assert_contains "$FORCED" "enabled" "an explicit override re-enables code access on a mismatch"

OFF=$(env GH_PR_ENRICH_CODE_ACCESS=false PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call resolve_code_access "$LOCAL_HEAD" 2>&1 || true)
assert_contains "$OFF" "disabled" "--no-code-access still wins over a matching revision"

# --- the rest of the decision matrix ---------------------------------------
# Ahead of the PR head: the normal state while addressing feedback, since fixing
# review comments means committing locally. That code is still the PR's code plus
# the fixes in progress, so access is granted and the report says so.
AHEAD_REPO="$TEST_OUTPUT_DIR/ahead-repo"
mkdir -p "$AHEAD_REPO"
(cd "$AHEAD_REPO" && git init -q . && git config user.email t@t && git config user.name t \
    && echo one > f.txt && git add -A && git commit -qm first \
    && echo two >> f.txt && git commit -qam second)
BASE_SHA=$(git -C "$AHEAD_REPO" rev-parse HEAD~1)

AHEAD=$( (cd "$AHEAD_REPO" && "$GH_PR_ENRICH" --test-call resolve_code_access "$BASE_SHA" 2>&1) || true)
assert_contains "$AHEAD" "enabled" "code access is enabled when the tree is ahead of the PR head"
assert_contains "$AHEAD" "1 commit(s) ahead" "the report says how far ahead the tree is"

# An unrelated repository is not "ahead" — it is a different history entirely.
UNRELATED="$TEST_OUTPUT_DIR/unrelated-repo"
mkdir -p "$UNRELATED"
(cd "$UNRELATED" && git init -q . && git config user.email t@t && git config user.name t \
    && echo other > g.txt && git add -A && git commit -qm only)
UNRELATED_OUT=$( (cd "$UNRELATED" && "$GH_PR_ENRICH" --test-call resolve_code_access "$BASE_SHA" 2>&1) || true)
assert_contains "$UNRELATED_OUT" "disabled" "an unrelated history does not count as ahead of the PR head"

# Not a git checkout at all. This has to live outside the repository, or git
# walks up and finds this checkout's HEAD.
NOGIT=$(mktemp -d)
trap 'rm -rf "$NOGIT"; cleanup' EXIT
NOGIT_OUT=$( (cd "$NOGIT" && "$GH_PR_ENRICH" --test-call resolve_code_access "$LOCAL_HEAD" 2>&1) || true)
assert_contains "$NOGIT_OUT" "disabled" "code access is disabled outside a git checkout"
assert_contains "$NOGIT_OUT" "not a git checkout" "the reason names the missing checkout"

NOGIT_FORCED=$( (cd "$NOGIT" && env GH_PR_ENRICH_CODE_ACCESS=true \
    "$GH_PR_ENRICH" --test-call resolve_code_access "$LOCAL_HEAD" 2>&1) || true)
assert_contains "$NOGIT_FORCED" "enabled" "the override also applies outside a git checkout"

# Unknown PR head (a summary without headRefOid).
UNKNOWN=$(revision_state "")
assert_contains "$UNKNOWN" "disabled" "code access is disabled when the PR head is unknown"
assert_contains "$UNKNOWN" "unknown" "the reason names the unknown revision"

UNKNOWN_FORCED=$(env GH_PR_ENRICH_CODE_ACCESS=true PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call resolve_code_access "" 2>&1 || true)
assert_contains "$UNKNOWN_FORCED" "enabled" "the override applies when the PR head is unknown"

# --- the CLI flags, not just the environment variable -----------------------
flag_state() {
    # Runs the real argument parser, then reports what the analyzer would be told.
    env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" 1 "$1" --enrich --output-dir "$TEST_OUTPUT_DIR/flag" 2>&1 || true
}
assert_contains "$(flag_state --no-code-access)" "WITHOUT repository access" \
    "--no-code-access reaches the analyzer"
assert_contains "$("$GH_PR_ENRICH" --help 2>&1)" "--code-access" "--code-access is documented in help"

# The whole run must record which revision was inspected.
REV_DIR="$TEST_OUTPUT_DIR/revision"
mkdir -p "$REV_DIR"
cat > "$REV_DIR/pr-summary.json" << EOF
{"number": 5, "title": "t", "body": "b", "author": {"login": "u"}, "files": [],
 "headRefOid": "$LOCAL_HEAD"}
EOF
echo '[]' > "$REV_DIR/unresolved-threads.json"
echo '[]' > "$REV_DIR/issue-comments.json"
"$GH_PR_ENRICH" --test-call build_claude_context "$REV_DIR" false >/dev/null 2>&1 || true

assert_jq "$REV_DIR/claude-context.json" '.coverage.code_access != null' \
    "coverage records the code-access state"
assert_jq "$REV_DIR/claude-context.json" '.coverage.code_access.pr_head_sha != null' \
    "coverage records the PR head revision"
assert_jq "$REV_DIR/claude-context.json" '.coverage.code_access.revision_matches == true' \
    "coverage records whether the inspected tree matches the PR"

# ---------------------------------------------------------------------------
# Failure paths must be diagnosable, and must not leak shell internals
# ---------------------------------------------------------------------------
FAIL_STUBS="$TEST_OUTPUT_DIR/fail-stubs"
mkdir -p "$FAIL_STUBS"
cp "$STUB_DIR/timeout" "$FAIL_STUBS/timeout"

# Analyzer killed by a signal (what a real timeout looks like)
cat > "$FAIL_STUBS/claude" << 'STUB'
#!/bin/bash
cat > /dev/null
kill -9 $$
STUB
chmod +x "$FAIL_STUBS/claude"

KILLED_OUT=$(env CLAUDE_ARG_LOG="$ARG_LOG" CLAUDE_TIMEOUT_LOG="$TEST_OUTPUT_DIR/timeout.txt" \
    PATH="$FAIL_STUBS:$PATH" "$GH_PR_ENRICH" --test-call run_claude_analysis \
    "$CONTEXT" "$TEST_OUTPUT_DIR/killed.json" 2>&1 || true)

assert_contains "$KILLED_OUT" "timed out" "a killed analyzer is reported as a timeout"
assert_not_contains "$KILLED_OUT" "Killed: 9" \
    "shell job-control noise is not printed to the user"
assert_not_contains "$KILLED_OUT" "--system-prompt" \
    "the full analyzer command line is not dumped on failure"

# Analyzer exits non-zero with a diagnostic
cat > "$FAIL_STUBS/claude" << 'STUB'
#!/bin/bash
cat > /dev/null
echo "API error: credit balance too low" >&2
exit 3
STUB
chmod +x "$FAIL_STUBS/claude"

rc=0
FAILED_OUT=$(env CLAUDE_ARG_LOG="$ARG_LOG" CLAUDE_TIMEOUT_LOG="$TEST_OUTPUT_DIR/timeout.txt" \
    PATH="$FAIL_STUBS:$PATH" "$GH_PR_ENRICH" --test-call run_claude_analysis \
    "$CONTEXT" "$TEST_OUTPUT_DIR/failed.json" 2>&1) || rc=$?

assert_eq "3" "$rc" "the analyzer's exit code is propagated to the caller"
assert_contains "$FAILED_OUT" "credit balance too low" \
    "the analyzer's own error message is surfaced, not swallowed"

# ---------------------------------------------------------------------------
# Missing and malformed context inputs fail clearly, not cryptically
# ---------------------------------------------------------------------------
MISSING_DIR="$TEST_OUTPUT_DIR/missing-summary"
mkdir -p "$MISSING_DIR"
rc=0
MISSING_OUT=$("$GH_PR_ENRICH" --test-call build_claude_context "$MISSING_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "missing pr-summary.json is an error"
assert_contains "$MISSING_OUT" "pr-summary.json" "the missing file is named in the error"
assert_not_contains "$MISSING_OUT" "invalid JSON text passed to --argjson" \
    "the user sees a clear error, not a raw jq argument error"

MALFORMED_DIR="$TEST_OUTPUT_DIR/malformed"
mkdir -p "$MALFORMED_DIR"
echo '{"number":1,"title":"t","body":"b","author":{"login":"u"},"files":[]}' > "$MALFORMED_DIR/pr-summary.json"
echo 'not json at all' > "$MALFORMED_DIR/unresolved-threads.json"
echo '[]' > "$MALFORMED_DIR/issue-comments.json"
rc=0
MALFORMED_OUT=$("$GH_PR_ENRICH" --test-call build_claude_context "$MALFORMED_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "malformed input JSON is an error"
assert_contains "$MALFORMED_OUT" "unresolved-threads.json" "the malformed file is named in the error"

# ---------------------------------------------------------------------------
# SAST pre-pass
# ---------------------------------------------------------------------------
# The collector scans changed files in the working tree, and only when that tree
# holds the PR's code — so the fixture is a real checkout whose HEAD is the
# declared PR head.
WORKSPACE="$TEST_OUTPUT_DIR/workspace"
SAST_DIR="$WORKSPACE/reports"
mkdir -p "$SAST_DIR" "$WORKSPACE/src"
echo "const x = 1;" > "$WORKSPACE/src/retry.js"
(cd "$WORKSPACE" && git init -q . && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm init)
WORKSPACE_HEAD=$(git -C "$WORKSPACE" rev-parse HEAD)
jq -n --arg sha "$WORKSPACE_HEAD" '{
    number: 1, title: "t", body: "", author: {login: "u"},
    files: [{path: "src/retry.js"}, {path: "src/deleted-by-this-pr.js"}],
    headRefOid: $sha
}' > "$SAST_DIR/pr-summary.json"

(cd "$WORKSPACE" && PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call collect_sast_findings "reports" >/dev/null 2>&1) || true
SAST_FILE="$SAST_DIR/sast-findings.json"

assert_jq_eq "$SAST_FILE" 'length' "1" "semgrep findings are collected"
assert_jq "$SAST_FILE" '.[0].path == "src/retry.js"' "finding carries its path"
assert_jq "$SAST_FILE" '.[0].line == 12' "finding carries its line"
assert_jq "$SAST_FILE" '.[0].severity == "ERROR"' "finding carries its severity"
assert_jq "$SAST_FILE" '.[0].check_id | contains("unsafe-exec")' "finding carries its rule id"
assert_jq "$SAST_FILE" '.[0].message | contains("unsafe exec")' "finding carries its message"

# The SAST pass reads the working tree, so it is governed by the same revision
# rule as the analyzer. Scanning `main` while analyzing someone else's PR yields
# findings with line anchors for code the PR does not contain — and those enter
# the context labelled as deterministic ground truth.
MISMATCH_WS="$TEST_OUTPUT_DIR/sast-mismatch"
mkdir -p "$MISMATCH_WS/reports" "$MISMATCH_WS/src"
echo "const x = 1;" > "$MISMATCH_WS/src/retry.js"
# A real checkout whose HEAD is not the declared PR head — the "reviewing someone
# else's PR from main" case, rather than the simpler not-a-repo case.
(cd "$MISMATCH_WS" && git init -q . && git config user.email t@t && git config user.name t \
    && git add -A && git commit -qm init)
cat > "$MISMATCH_WS/reports/pr-summary.json" << 'EOF'
{"number": 1, "title": "t", "body": "", "author": {"login": "u"},
 "files": [{"path": "src/retry.js"}],
 "headRefOid": "0000000000000000000000000000000000000000"}
EOF

MISMATCH_OUT=$( (cd "$MISMATCH_WS" && PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call collect_sast_findings "reports" 2>&1) || true)

assert_contains "$MISMATCH_OUT" "Skipping the semgrep pre-pass" \
    "the SAST pass is skipped when the tree is not the PR revision"
assert_contains "$MISMATCH_OUT" "but the PR head is" \
    "the skip message names the revision mismatch"
assert_jq_eq "$MISMATCH_WS/reports/sast-findings.json" 'length' "0" \
    "no SAST findings are fabricated from the wrong revision"

# Changed-file paths from GitHub are repository-relative. Resolving them against
# the current directory silently drops every target when the extension is run
# from a subdirectory — a skipped scan that looks like a clean one.
SUBDIR_WS="$TEST_OUTPUT_DIR/sast-subdir"
mkdir -p "$SUBDIR_WS/src" "$SUBDIR_WS/reports"
(cd "$SUBDIR_WS" && git init -q . && git config user.email t@t && git config user.name t)
echo "const x = 1;" > "$SUBDIR_WS/src/retry.js"
(cd "$SUBDIR_WS" && git add -A && git commit -qm init)
SUBDIR_HEAD=$(git -C "$SUBDIR_WS" rev-parse HEAD)
jq -n --arg sha "$SUBDIR_HEAD" '{number: 1, title: "t", body: "", author: {login: "u"},
    files: [{path: "src/retry.js"}], headRefOid: $sha}' > "$SUBDIR_WS/reports/pr-summary.json"

SUBDIR_OUT=$( (cd "$SUBDIR_WS/src" && PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call collect_sast_findings "../reports" 2>&1) || true)

assert_jq_eq "$SUBDIR_WS/reports/sast-findings.json" 'length' "1" \
    "changed files are found when running from a subdirectory"
assert_not_contains "$SUBDIR_OUT" "No changed files present" \
    "the scan is not silently skipped from a subdirectory"

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
