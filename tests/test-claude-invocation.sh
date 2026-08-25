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
[ -z "${CLAUDE_TIMEOUT_LOG:-}" ] || \
    printf '%s' "$GH_PR_ENRICH_ANALYZER_TIMEOUT_SECONDS" > "$CLAUDE_TIMEOUT_LOG"
previous=""
for argument in "$@"; do
    if [ "$previous" = "--settings" ]; then
        printf '%s\n' "$argument" > "$CLAUDE_SETTINGS_PATH_LOG"
        cp "$argument" "$CLAUDE_SETTINGS_LOG"
    fi
    previous="$argument"
done
cat > /dev/null
[ -z "${CLAUDE_STUB_DELAY:-}" ] || /bin/sleep "$CLAUDE_STUB_DELAY"
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

cat > "$STUB_DIR/cp" << 'STUB'
#!/bin/bash
previous=""
for argument in "$@"; do
    previous="$argument"
done
case "$previous" in
    /tmp/gh-pr-enrich-claude-context.*|/private/tmp/gh-pr-enrich-claude-context.*)
        [ -z "${ANALYZER_CONTEXT_COPY_LOG:-}" ] || \
            printf '%s\n' "$previous" >> "$ANALYZER_CONTEXT_COPY_LOG"
        ;;
esac
exec /bin/cp "$@"
STUB
chmod +x "$STUB_DIR/cp"

PS_CALLED_LOG="$TEST_OUTPUT_DIR/ps-called.log"
: > "$PS_CALLED_LOG"
cat > "$STUB_DIR/ps" << 'STUB'
#!/bin/bash
printf 'ps invoked\n' >> "$PS_CALLED_LOG"
exit 97
STUB
chmod +x "$STUB_DIR/ps"

cat > "$STUB_DIR/sleep" << 'STUB'
#!/bin/bash
[ -z "${SLEEP_INTERVAL_LOG:-}" ] || printf '%s\n' "$1" >> "$SLEEP_INTERVAL_LOG"
[ -z "${SLEEP_PID_LOG:-}" ] || printf '%s\n' "$$" > "$SLEEP_PID_LOG"
[ "${SLEEP_FAIL_INTERVAL:-}" != "$1" ] || exit 64
exec /bin/sleep "$@"
STUB
chmod +x "$STUB_DIR/sleep"

cat > "$STUB_DIR/semgrep" << 'STUB'
#!/bin/bash
[ -z "${SEMGREP_CWD_LOG:-}" ] || pwd > "$SEMGREP_CWD_LOG"
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

# The CLI-flag check below runs the real end-to-end enrichment path. Keep that
# path independent of the developer's gh authentication and Actions' token
# environment so it reaches the analyzer on every platform.
cat > "$STUB_DIR/gh" << 'STUB'
#!/bin/bash
case "$1 $2" in
    "repo view")
        echo '{"nameWithOwner":"o/r","visibility":"PUBLIC"}'
        exit 0
        ;;
    "pr view")
        cat << 'JSON'
{"number":1,"title":"t","body":"b","author":{"login":"u"},"state":"OPEN",
 "url":"https://github.com/o/r/pull/1","createdAt":"2026-01-01T00:00:00Z",
 "updatedAt":"2026-01-01T00:00:00Z","mergeable":"MERGEABLE","isDraft":false,
 "additions":1,"deletions":0,"changedFiles":1,"headRefOid":"abc123",
 "files":[{"path":"a.js","additions":1,"deletions":0}],"commits":[],
 "labels":[],"assignees":[],"reviews":[]}
JSON
        exit 0
        ;;
    "pr checks") echo '[]'; exit 0 ;;
esac
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    case "$*" in
        *closingIssuesReferences*)
            echo '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
            ;;
        *)
            echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PRRT_open","isResolved":false,"isOutdated":false,"path":"a.js","line":1,"comments":{"nodes":[{"id":"c","databaseId":1,"body":"check this","author":{"login":"rev"},"createdAt":"2026-01-01T00:00:00Z","url":"https://github.com/o/r/pull/1#discussion_r1"}]}}]}}}}}'
            ;;
    esac
    exit 0
fi
if [ "$1" = "api" ]; then echo '[]'; exit 0; fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"

CONTEXT="$TEST_OUTPUT_DIR/claude-context.json"
# The context records the PR head; the analyzer re-checks it against the working
# tree before granting tools, so the fixture claims the revision under test.
CODE_ACCESS_REPO="$TEST_OUTPUT_DIR/code-access-repo"
mkdir -p "$CODE_ACCESS_REPO"
(cd "$CODE_ACCESS_REPO" && git init -q . && git config user.email t@t && git config user.name t \
    && printf '.env\n' > .gitignore && echo clean > tracked.txt && git add -A && git commit -qm init)
HEAD_SHA=$(git -C "$CODE_ACCESS_REPO" rev-parse HEAD)

# Generated report files change during analysis and are excluded individually.
# An unexpected file beside them remains part of the bound workspace.
FINGERPRINT_REPORT="$CODE_ACCESS_REPO/report"
mkdir -p "$FINGERPRINT_REPORT"
FINGERPRINT_BASE=$(cd "$CODE_ACCESS_REPO" && \
    "$GH_PR_ENRICH" --test-call code_access_workspace_fingerprint "$FINGERPRINT_REPORT")
echo generated > "$FINGERPRINT_REPORT/claude-raw-response.json"
FINGERPRINT_WITH_GENERATED=$(cd "$CODE_ACCESS_REPO" && \
    "$GH_PR_ENRICH" --test-call code_access_workspace_fingerprint "$FINGERPRINT_REPORT")
assert_eq "$FINGERPRINT_BASE" "$FINGERPRINT_WITH_GENERATED" \
    "allowlisted generated report artifacts do not change the workspace fingerprint"
echo unexpected > "$FINGERPRINT_REPORT/unexpected.txt"
FINGERPRINT_WITH_UNEXPECTED=$(cd "$CODE_ACCESS_REPO" && \
    "$GH_PR_ENRICH" --test-call code_access_workspace_fingerprint "$FINGERPRINT_REPORT")
assert_true "$([ "$FINGERPRINT_WITH_GENERATED" != "$FINGERPRINT_WITH_UNEXPECTED" ] && echo 0 || echo 1)" \
    "unexpected output-directory files change the workspace fingerprint"
rm "$FINGERPRINT_REPORT/unexpected.txt"
mkdir -p "$FINGERPRINT_REPORT/analysis.json"
echo nested > "$FINGERPRINT_REPORT/analysis.json/payload"
FINGERPRINT_WITH_DESCENDANT=$(cd "$CODE_ACCESS_REPO" && \
    "$GH_PR_ENRICH" --test-call code_access_workspace_fingerprint "$FINGERPRINT_REPORT")
assert_true "$([ "$FINGERPRINT_WITH_GENERATED" != "$FINGERPRINT_WITH_DESCENDANT" ] && echo 0 || echo 1)" \
    "descendants of allowlisted artifact names remain bound to the workspace"
rm "$FINGERPRINT_REPORT/analysis.json/payload"
rmdir "$FINGERPRINT_REPORT/analysis.json"

ln -s ../tracked.txt "$FINGERPRINT_REPORT/claude-analysis.json"
rc=0
(cd "$CODE_ACCESS_REPO" && "$GH_PR_ENRICH" --test-call \
    code_access_workspace_fingerprint "$FINGERPRINT_REPORT" >/dev/null 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "repository-visible symlinks fail closed even when their names are allowlisted"
rm "$FINGERPRINT_REPORT/claude-analysis.json" "$FINGERPRINT_REPORT/claude-raw-response.json"
rmdir "$FINGERPRINT_REPORT"

ln -s tracked.txt "$CODE_ACCESS_REPO/.env"
rc=0
(cd "$CODE_ACCESS_REPO" && "$GH_PR_ENRICH" --test-call \
    code_access_workspace_fingerprint "$TEST_OUTPUT_DIR" >/dev/null 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "ignored repository-visible symlinks fail closed"
rm "$CODE_ACCESS_REPO/.env"

ln -s tracked.txt "$CODE_ACCESS_REPO/tracked-link"
git -C "$CODE_ACCESS_REPO" add tracked-link
rc=0
(cd "$CODE_ACCESS_REPO" && "$GH_PR_ENRICH" --test-call \
    code_access_workspace_fingerprint "$TEST_OUTPUT_DIR" >/dev/null 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "tracked repository-visible symlinks fail closed"
git -C "$CODE_ACCESS_REPO" reset -q HEAD -- tracked-link
rm "$CODE_ACCESS_REPO/tracked-link"

NESTED_REPO="$CODE_ACCESS_REPO/nested-repo"
mkdir -p "$NESTED_REPO"
(cd "$NESTED_REPO" && git init -q . && git config user.email t@t && \
    git config user.name t && echo nested > nested.txt && git add nested.txt && \
    git commit -qm init)
rc=0
(cd "$CODE_ACCESS_REPO" && "$GH_PR_ENRICH" --test-call \
    code_access_workspace_fingerprint "$TEST_OUTPUT_DIR" >/dev/null 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "nested repositories fail closed instead of hashing only their directory entry"
rm -rf "$NESTED_REPO"

git -C "$CODE_ACCESS_REPO" update-index --skip-worktree tracked.txt
SKIP_WORKTREE_BASE=$(cd "$CODE_ACCESS_REPO" && \
    "$GH_PR_ENRICH" --test-call code_access_workspace_fingerprint "$TEST_OUTPUT_DIR")
echo hidden-from-git-diff > "$CODE_ACCESS_REPO/tracked.txt"
SKIP_WORKTREE_CHANGED=$(cd "$CODE_ACCESS_REPO" && \
    "$GH_PR_ENRICH" --test-call code_access_workspace_fingerprint "$TEST_OUTPUT_DIR")
assert_true "$([ "$SKIP_WORKTREE_BASE" != "$SKIP_WORKTREE_CHANGED" ] && echo 0 || echo 1)" \
    "skip-worktree cannot hide changed tracked bytes from the workspace fingerprint"
cp "$CODE_ACCESS_REPO/tracked.txt" "$TEST_OUTPUT_DIR/tracked-before-missing.txt"
rm "$CODE_ACCESS_REPO/tracked.txt"
rc=0
(cd "$CODE_ACCESS_REPO" && "$GH_PR_ENRICH" --test-call \
    code_access_workspace_fingerprint "$TEST_OUTPUT_DIR" >/dev/null 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a missing skip-worktree path disables code access instead of omitting tracked code"
cp "$TEST_OUTPUT_DIR/tracked-before-missing.txt" "$CODE_ACCESS_REPO/tracked.txt"
git -C "$CODE_ACCESS_REPO" update-index --no-skip-worktree tracked.txt
git -C "$CODE_ACCESS_REPO" checkout -- tracked.txt

WORKSPACE_FINGERPRINT=$(cd "$CODE_ACCESS_REPO" && \
    "$GH_PR_ENRICH" --test-call code_access_workspace_fingerprint "$TEST_OUTPUT_DIR")
jq -n --arg sha "$HEAD_SHA" --arg workspace_fingerprint "$WORKSPACE_FINGERPRINT" '{
    pr: {title: "t"}, unresolved_threads: [], issue_comments: [],
    coverage: {code_access: {
        state: "enabled", reason: "fixture",
        pr_head_sha: $sha, inspected_sha: $sha, revision_matches: true,
        workspace_fingerprint: $workspace_fingerprint
    }}
}' > "$CONTEXT.tmp"
CONTEXT_FINGERPRINT=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint "$CONTEXT.tmp")
jq --arg fingerprint "$CONTEXT_FINGERPRINT" '.coverage.context_fingerprint = $fingerprint' \
    "$CONTEXT.tmp" > "$CONTEXT"
rm "$CONTEXT.tmp"
RESPONSE="$TEST_OUTPUT_DIR/response.json"

NATIVE_REPORT="$CODE_ACCESS_REPO/report"
mkdir -p "$NATIVE_REPORT"
cp "$CONTEXT" "$NATIVE_REPORT/analysis-context.json"
NATIVE_SNAPSHOT_JSON=$(cd "$CODE_ACCESS_REPO" && \
    env PS_CALLED_LOG="$PS_CALLED_LOG" PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" materialize-analysis-snapshot "$NATIVE_REPORT")
NATIVE_SNAPSHOT_PATH=$(printf '%s' "$NATIVE_SNAPSHOT_JSON" | jq -r '.path')
assert_eq "$WORKSPACE_FINGERPRINT" \
    "$(printf '%s' "$NATIVE_SNAPSHOT_JSON" | jq -r '.workspace_fingerprint')" \
    "native snapshot materialization reports the validated workspace fingerprint"
assert_eq "clean" "$(cat "$NATIVE_SNAPSHOT_PATH/tracked.txt")" \
    "native snapshot materialization copies the bound repository bytes"
assert_true "$([ ! -w "$NATIVE_SNAPSHOT_PATH/tracked.txt" ] && echo 0 || echo 1)" \
    "native snapshot materialization produces read-only files"
NATIVE_JANITOR_SIDECAR="$NATIVE_SNAPSHOT_PATH.janitor"
NATIVE_JANITOR_PID=$(awk -F '\t' 'NR == 1 { print $2 }' "$NATIVE_JANITOR_SIDECAR")
assert_true "$([ -n "$NATIVE_JANITOR_PID" ] && kill -0 "$NATIVE_JANITOR_PID" 2>/dev/null && echo 0 || echo 1)" \
    "native snapshot materialization records a live bounded-lease janitor"
env PS_CALLED_LOG="$PS_CALLED_LOG" PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" cleanup-analysis-snapshot "$NATIVE_SNAPSHOT_PATH"
assert_true "$([ ! -e "$NATIVE_SNAPSHOT_PATH" ] && echo 0 || echo 1)" \
    "native snapshot cleanup removes the leased private directory"
for _attempt in $(seq 1 100); do
    ! kill -0 "$NATIVE_JANITOR_PID" 2>/dev/null && break
    sleep 0.01
done
assert_true "$([ ! -e "$NATIVE_JANITOR_SIDECAR" ] && ! kill -0 "$NATIVE_JANITOR_PID" 2>/dev/null && echo 0 || echo 1)" \
    "explicit snapshot cleanup stops the recorded janitor and removes its sidecar"

EXPIRING_SNAPSHOT_JSON=$(cd "$CODE_ACCESS_REPO" && \
    env GH_PR_ENRICH_SNAPSHOT_TTL_SECONDS=1 \
    PS_CALLED_LOG="$PS_CALLED_LOG" PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" materialize-analysis-snapshot "$NATIVE_REPORT")
EXPIRING_SNAPSHOT_PATH=$(printf '%s' "$EXPIRING_SNAPSHOT_JSON" | jq -r '.path')
EXPIRING_JANITOR_SIDECAR="$EXPIRING_SNAPSHOT_PATH.janitor"
EXPIRING_JANITOR_PID=$(awk -F '\t' 'NR == 1 { print $2 }' "$EXPIRING_JANITOR_SIDECAR")
assert_eq "1" "$(printf '%s' "$EXPIRING_SNAPSHOT_JSON" | jq -r '.expires_in_seconds')" \
    "native snapshot materialization reports its bounded lease"
for _attempt in $(seq 1 100); do
    [ ! -e "$EXPIRING_SNAPSHOT_PATH" ] && break
    sleep 0.05
done
assert_true "$([ ! -e "$EXPIRING_SNAPSHOT_PATH" ] && echo 0 || echo 1)" \
    "the native snapshot janitor reaps an abandoned short lease"
for _attempt in $(seq 1 100); do
    ! kill -0 "$EXPIRING_JANITOR_PID" 2>/dev/null && break
    sleep 0.01
done
assert_true "$([ ! -e "$EXPIRING_JANITOR_SIDECAR" ] && ! kill -0 "$EXPIRING_JANITOR_PID" 2>/dev/null && echo 0 || echo 1)" \
    "TTL expiry removes the lease sidecar and leaves no janitor process"
for INVALID_SNAPSHOT_TTL in nope 999999999999999999999999999999; do
    BOUNDED_SNAPSHOT_JSON=$(cd "$CODE_ACCESS_REPO" && \
        env GH_PR_ENRICH_SNAPSHOT_TTL_SECONDS="$INVALID_SNAPSHOT_TTL" \
        PS_CALLED_LOG="$PS_CALLED_LOG" PATH="$STUB_DIR:$PATH" \
        "$GH_PR_ENRICH" materialize-analysis-snapshot "$NATIVE_REPORT")
    BOUNDED_SNAPSHOT_PATH=$(printf '%s' "$BOUNDED_SNAPSHOT_JSON" | jq -r '.path')
    assert_eq "3600" \
        "$(printf '%s' "$BOUNDED_SNAPSHOT_JSON" | jq -r '.expires_in_seconds')" \
        "invalid native snapshot TTL '$INVALID_SNAPSHOT_TTL' uses the bounded default"
    "$GH_PR_ENRICH" cleanup-analysis-snapshot "$BOUNDED_SNAPSHOT_PATH"
done
rm -f "$NATIVE_REPORT/analysis-context.json"
rmdir "$NATIVE_REPORT"

run_analysis_context() {
    local context_file="$1"
    shift
    (cd "$CODE_ACCESS_REPO" && env CLAUDE_ARG_LOG="$ARG_LOG" \
        ANALYZER_CONTEXT_COPY_LOG="$TEST_OUTPUT_DIR/context-copy-paths.txt" \
        CLAUDE_SETTINGS_LOG="$TEST_OUTPUT_DIR/claude-settings.json" \
        CLAUDE_SETTINGS_PATH_LOG="$TEST_OUTPUT_DIR/claude-settings-path.txt" \
        CLAUDE_TIMEOUT_LOG="$TEST_OUTPUT_DIR/timeout.txt" \
        PATH="$STUB_DIR:$PATH" "$@" \
        "$GH_PR_ENRICH" --test-call run_claude_analysis "$context_file" "$RESPONSE" >/dev/null 2>&1) || true
}

run_analysis() {
    run_analysis_context "$CONTEXT" "$@"
}

# ---------------------------------------------------------------------------
# Code access
# ---------------------------------------------------------------------------
run_analysis
ARGS=$(cat "$ARG_LOG" 2>/dev/null || echo "")

assert_contains "$ARGS" "--allowedTools" "analyzer is granted tools by default"
assert_contains "$ARGS" "Read(./**)" "analyzer read access is scoped to the snapshot"
assert_contains "$ARGS" "Grep" "analyzer may grep the repository"
assert_contains "$ARGS" "Glob" "analyzer may glob the repository"
assert_not_contains "$ARGS" "Bash" "analyzer is not granted Bash"
assert_not_contains "$ARGS" "Write" "analyzer is not granted Write"
assert_not_contains "$ARGS" "Edit" "analyzer is not granted Edit"
assert_contains "$ARGS" "--json-schema" "analyzer is given the structured-output schema"
assert_contains "$ARGS" "--tools" "the available Claude tools are explicitly restricted"
assert_contains "$ARGS" "--permission-mode" "Claude cannot pause for permission prompts"
assert_contains "$ARGS" "dontAsk" "Claude uses the non-interactive permission mode"
assert_contains "$ARGS" "--no-session-persistence" "Claude analysis does not persist a session"
TOOLS_ARGS=$(awk '/^--tools$/{capture=1;next} /^--allowedTools$/{capture=0} capture' "$ARG_LOG")
ALLOWED_ARGS=$(awk '/^--allowedTools$/{capture=1;next} /^--settings$/{capture=0} capture' "$ARG_LOG")
assert_eq $'Read\nGrep\nGlob' "$TOOLS_ARGS" \
    "Claude --tools receives only bare built-in tool names"
assert_eq $'Read(./**)\nGrep\nGlob' "$ALLOWED_ARGS" \
    "Claude --allowedTools scopes Read to the immutable snapshot"
EXPECTED_DENY="Read(//${CODE_ACCESS_REPO#/}/**)"
rc=0
jq -e --arg expected "$EXPECTED_DENY" \
    '.permissions.deny == [$expected]' \
    "$TEST_OUTPUT_DIR/claude-settings.json" > /dev/null 2>&1 || rc=$?
assert_true "$rc" "Claude settings deny the original repository by absolute path"
CLAUDE_SETTINGS_PATH=$(cat "$TEST_OUTPUT_DIR/claude-settings-path.txt")
assert_true "$([ ! -e "$CLAUDE_SETTINGS_PATH" ] && echo 0 || echo 1)" \
    "the isolated Claude settings file is removed after analysis"
SUCCESS_CONTEXT_COPY=$(tail -1 "$TEST_OUTPUT_DIR/context-copy-paths.txt" 2>/dev/null || echo "")
assert_true "$([ -n "$SUCCESS_CONTEXT_COPY" ] && \
    [ ! -e "$SUCCESS_CONTEXT_COPY" ] && echo 0 || echo 1)" \
    "successful analysis removes its immutable context copy"

# A context that deliberately withheld code access still runs without tools.
NO_CODE_CONTEXT="$TEST_OUTPUT_DIR/no-code-context.json"
jq '.coverage.code_access = {
        state: "disabled", reason: "fixture opt-out",
        pr_head_sha: .coverage.code_access.pr_head_sha,
        inspected_sha: .coverage.code_access.inspected_sha,
        revision_matches: true, workspace_fingerprint: null
    } | del(.coverage.context_fingerprint)' "$CONTEXT" > "$NO_CODE_CONTEXT.tmp"
NO_CODE_FINGERPRINT=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint "$NO_CODE_CONTEXT.tmp")
jq --arg fingerprint "$NO_CODE_FINGERPRINT" '.coverage.context_fingerprint = $fingerprint' \
    "$NO_CODE_CONTEXT.tmp" > "$NO_CODE_CONTEXT"
rm "$NO_CODE_CONTEXT.tmp"
run_analysis_context "$NO_CODE_CONTEXT" GH_PR_ENRICH_CODE_ACCESS=false
ARGS_NO_CODE=$(cat "$ARG_LOG" 2>/dev/null || echo "")
assert_not_contains "$ARGS_NO_CODE" "--allowedTools" "code access can be disabled"
assert_contains "$ARGS_NO_CODE" "--tools" "the no-code run explicitly disables Claude tools"
assert_not_contains "$ARGS_NO_CODE" "Read" "the no-code run cannot read repository files"

# A tree that stopped matching after context capture cannot silently downgrade
# an enabled run and later publish confirmed output against the old context.
rm -f "$ARG_LOG" "$RESPONSE"
echo pre-run-mutation >> "$CODE_ACCESS_REPO/tracked.txt"
rc=0
PRE_RUN_MISMATCH=$(cd "$CODE_ACCESS_REPO" && env CLAUDE_ARG_LOG="$ARG_LOG" \
    CLAUDE_TIMEOUT_LOG="$TEST_OUTPUT_DIR/timeout.txt" PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call run_claude_analysis "$CONTEXT" "$RESPONSE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "an enabled context fails closed when code access is withheld before the run"
assert_contains "$PRE_RUN_MISMATCH" "no longer matches the fingerprinted context" \
    "the pre-run mismatch identifies the stale code-access grant"
assert_true "$([ ! -s "$ARG_LOG" ] && echo 0 || echo 1)" \
    "a pre-run workspace mismatch is rejected before invoking Claude"
git -C "$CODE_ACCESS_REPO" checkout -- tracked.txt

# Prompt construction freezes and binds the context bytes. Swapping A to B
# only for the copy, then restoring A before the immediate live check, must not
# let Claude analyze B under A's fingerprinted provenance.
PROMPT_ABA_CONTEXT="$TEST_OUTPUT_DIR/prompt-aba-context.json"
PROMPT_ABA_CONTEXT_A="$TEST_OUTPUT_DIR/prompt-aba-context-a.json"
PROMPT_ABA_CONTEXT_B="$TEST_OUTPUT_DIR/prompt-aba-context-b.json"
PROMPT_ABA_STUB_DIR="$TEST_OUTPUT_DIR/prompt-aba-stubs"
PROMPT_ABA_FROZEN_LOG="$TEST_OUTPUT_DIR/prompt-aba-frozen-path.txt"
mkdir -p "$PROMPT_ABA_STUB_DIR"
cp "$CONTEXT" "$PROMPT_ABA_CONTEXT"
cp "$PROMPT_ABA_CONTEXT" "$PROMPT_ABA_CONTEXT_A"
jq 'del(.coverage.context_fingerprint) | .pr.title = "state-b-only"' \
    "$PROMPT_ABA_CONTEXT" > "$PROMPT_ABA_CONTEXT_B.tmp"
PROMPT_ABA_FINGERPRINT=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
    "$PROMPT_ABA_CONTEXT_B.tmp")
jq --arg fingerprint "$PROMPT_ABA_FINGERPRINT" \
    '.coverage.context_fingerprint = $fingerprint' \
    "$PROMPT_ABA_CONTEXT_B.tmp" > "$PROMPT_ABA_CONTEXT_B"
rm "$PROMPT_ABA_CONTEXT_B.tmp"
cat > "$PROMPT_ABA_STUB_DIR/cp" << 'STUB'
#!/bin/bash
copy_source=""
previous=""
for argument in "$@"; do
    copy_source="$previous"
    previous="$argument"
done
if [ "$copy_source" = "$PROMPT_ABA_CONTEXT" ]; then
    printf '%s\n' "$previous" > "$PROMPT_ABA_FROZEN_LOG"
    "$REAL_CP" "$PROMPT_ABA_CONTEXT_B" "$PROMPT_ABA_CONTEXT"
    "$REAL_CP" "$@" || exit $?
    "$REAL_CP" "$PROMPT_ABA_CONTEXT_A" "$PROMPT_ABA_CONTEXT"
    exit 0
fi
exec "$REAL_CP" "$@"
STUB
chmod +x "$PROMPT_ABA_STUB_DIR/cp"
rm -f "$ARG_LOG" "$RESPONSE" "$PROMPT_ABA_FROZEN_LOG"
rc=0
PROMPT_ABA_OUT=$(cd "$CODE_ACCESS_REPO" && env \
    REAL_CP="$(command -v cp)" PROMPT_ABA_CONTEXT="$PROMPT_ABA_CONTEXT" \
    PROMPT_ABA_CONTEXT_A="$PROMPT_ABA_CONTEXT_A" \
    PROMPT_ABA_CONTEXT_B="$PROMPT_ABA_CONTEXT_B" \
    PROMPT_ABA_FROZEN_LOG="$PROMPT_ABA_FROZEN_LOG" \
    CLAUDE_ARG_LOG="$ARG_LOG" CLAUDE_TIMEOUT_LOG="$TEST_OUTPUT_DIR/timeout.txt" \
    PATH="$PROMPT_ABA_STUB_DIR:$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call run_claude_analysis \
    "$PROMPT_ABA_CONTEXT" "$RESPONSE" 2>&1) || rc=$?
PROMPT_ABA_FROZEN=$(cat "$PROMPT_ABA_FROZEN_LOG" 2>/dev/null || echo "")
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "prompt construction rejects a context ABA during immutable capture"
assert_contains "$PROMPT_ABA_OUT" "context changed while its immutable copy" \
    "the prompt-capture ABA is reported at the copy boundary"
assert_true "$([ ! -s "$ARG_LOG" ] && echo 0 || echo 1)" \
    "a prompt-capture ABA is rejected before invoking Claude"
assert_true "$(cmp -s "$PROMPT_ABA_CONTEXT" "$PROMPT_ABA_CONTEXT_A"; echo $?)" \
    "the prompt-capture ABA fixture restores live context state A"
assert_true "$([ -n "$PROMPT_ABA_FROZEN" ] && \
    [ ! -e "$PROMPT_ABA_FROZEN" ] && echo 0 || echo 1)" \
    "the rejected immutable context copy is removed"

# The shipped enrichment flow invokes run_claude_analysis as an if condition,
# which disables implicit errexit behavior inside the function. A failed read
# of the frozen context must still fail explicitly instead of invoking Claude
# with an empty prompt and stamping the response with captured provenance.
FROZEN_CAT_STUB_DIR="$TEST_OUTPUT_DIR/frozen-cat-stubs"
FROZEN_CAT_REPORT="$TEST_OUTPUT_DIR/frozen-cat-report"
FROZEN_CAT_ARG_LOG="$TEST_OUTPUT_DIR/frozen-cat-claude-args.txt"
FROZEN_CAT_COPY_LOG="$TEST_OUTPUT_DIR/frozen-cat-copy-path.txt"
mkdir -p "$FROZEN_CAT_STUB_DIR"
cat > "$FROZEN_CAT_STUB_DIR/cat" << 'STUB'
#!/bin/bash
case "${1:-}" in
    /tmp/gh-pr-enrich-claude-context.*|/private/tmp/gh-pr-enrich-claude-context.*)
        exit 88
        ;;
esac
exec /bin/cat "$@"
STUB
chmod +x "$FROZEN_CAT_STUB_DIR/cat"
rm -f "$FROZEN_CAT_ARG_LOG" "$FROZEN_CAT_COPY_LOG"
FROZEN_CAT_OUT=$(cd "$CODE_ACCESS_REPO" && env \
    CLAUDE_ARG_LOG="$FROZEN_CAT_ARG_LOG" \
    ANALYZER_CONTEXT_COPY_LOG="$FROZEN_CAT_COPY_LOG" \
    CLAUDE_TIMEOUT_LOG="$TEST_OUTPUT_DIR/timeout.txt" \
    PATH="$FROZEN_CAT_STUB_DIR:$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" 1 --enrich --allow-external \
    --output-dir "$FROZEN_CAT_REPORT" 2>&1)
FROZEN_CAT_COPY=$(tail -1 "$FROZEN_CAT_COPY_LOG" 2>/dev/null || echo "")
assert_contains "$FROZEN_CAT_OUT" \
    "Immutable analysis context could not be read before Claude analysis" \
    "the main if-call flow fails explicitly when the frozen context cannot be read"
assert_true "$([ ! -s "$FROZEN_CAT_ARG_LOG" ] && echo 0 || echo 1)" \
    "a frozen-context read failure never invokes Claude"
assert_true "$([ ! -e "$FROZEN_CAT_REPORT/claude-raw-response.json" ] && echo 0 || echo 1)" \
    "a frozen-context read failure publishes no analyzer response"
assert_true "$([ -n "$FROZEN_CAT_COPY" ] && \
    [ ! -e "$FROZEN_CAT_COPY" ] && echo 0 || echo 1)" \
    "a frozen-context read failure removes its immutable copy"

# Mutating the workspace from inside the analyzer stub deterministically models
# another process changing local code during a long Claude run.
MUTATION_STUB_DIR="$TEST_OUTPUT_DIR/mutation-stubs"
mkdir -p "$MUTATION_STUB_DIR"
cp "$STUB_DIR/timeout" "$MUTATION_STUB_DIR/timeout"
cat > "$MUTATION_STUB_DIR/claude" << 'STUB'
#!/bin/bash
cat > /dev/null
[ -z "${SNAPSHOT_CWD_LOG:-}" ] || printf '%s\n' "$PWD" > "$SNAPSHOT_CWD_LOG"
[ -z "${SNAPSHOT_READ_LOG:-}" ] || cat tracked.txt > "$SNAPSHOT_READ_LOG"
[ -z "${MUTATION_TARGET:-}" ] || echo changed-during-run >> "$MUTATION_TARGET"
[ -z "${MUTATION_BACKUP:-}" ] || cp "$MUTATION_BACKUP" "$MUTATION_TARGET"
[ -z "${SNAPSHOT_READ_LOG:-}" ] || cat tracked.txt >> "$SNAPSHOT_READ_LOG"
if [ -n "${CONTEXT_MUTATION_TARGET:-}" ]; then
    jq '.issue_comments += [{user:"race",body:"changed",url:"u",created_at:"t"}]' \
        "$CONTEXT_MUTATION_TARGET" > "$CONTEXT_MUTATION_TARGET.tmp"
    mv "$CONTEXT_MUTATION_TARGET.tmp" "$CONTEXT_MUTATION_TARGET"
fi
echo '{"structured_output": {"issue_categories": [], "category_coverage": [], "disputed_comments": [], "systemic_issues": [], "adjacent_problems": [], "task_list": [], "process_improvements": [], "pr_template_suggestions": []}}'
STUB
chmod +x "$MUTATION_STUB_DIR/claude"
rm -f "$RESPONSE"
rc=0
DURING_RUN_MISMATCH=$(cd "$CODE_ACCESS_REPO" && env MUTATION_TARGET="$CODE_ACCESS_REPO/tracked.txt" \
    CLAUDE_TIMEOUT_LOG="$TEST_OUTPUT_DIR/timeout.txt" PATH="$MUTATION_STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call run_claude_analysis "$CONTEXT" "$RESPONSE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "an analyzer response is rejected when the workspace changes during the run"
assert_contains "$DURING_RUN_MISMATCH" "workspace changed during Claude analysis" \
    "the during-run failure identifies the local workspace race"
assert_true "$([ ! -e "$RESPONSE" ] && echo 0 || echo 1)" \
    "a response produced across two workspace states is removed"
git -C "$CODE_ACCESS_REPO" checkout -- tracked.txt

MUTATION_BACKUP="$TEST_OUTPUT_DIR/tracked-backup.txt"
SNAPSHOT_CWD_LOG="$TEST_OUTPUT_DIR/snapshot-cwd.txt"
SNAPSHOT_READ_LOG="$TEST_OUTPUT_DIR/snapshot-read.txt"
cp "$CODE_ACCESS_REPO/tracked.txt" "$MUTATION_BACKUP"
rm -f "$RESPONSE" "$SNAPSHOT_CWD_LOG" "$SNAPSHOT_READ_LOG"
rc=0
(cd "$CODE_ACCESS_REPO" && env MUTATION_TARGET="$CODE_ACCESS_REPO/tracked.txt" \
    MUTATION_BACKUP="$MUTATION_BACKUP" SNAPSHOT_CWD_LOG="$SNAPSHOT_CWD_LOG" \
    SNAPSHOT_READ_LOG="$SNAPSHOT_READ_LOG" \
    CLAUDE_TIMEOUT_LOG="$TEST_OUTPUT_DIR/timeout.txt" PATH="$MUTATION_STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call run_claude_analysis "$CONTEXT" "$RESPONSE" \
    >/dev/null 2>&1) || rc=$?
SNAPSHOT_CWD=$(cat "$SNAPSHOT_CWD_LOG" 2>/dev/null || echo "")
assert_eq "0" "$rc" \
    "an analyzer isolated from the live tree accepts an original-tree ABA mutation"
assert_not_contains "$SNAPSHOT_CWD" "$CODE_ACCESS_REPO" \
    "code-enabled Claude runs outside the original repository"
assert_eq $'clean\nclean' "$(cat "$SNAPSHOT_READ_LOG")" \
    "the analyzer reads stable bytes from the frozen snapshot across the ABA mutation"
assert_true "$([ ! -d "$SNAPSHOT_CWD" ] && echo 0 || echo 1)" \
    "the private analyzer snapshot is removed after success"

SIGNAL_STUB_DIR="$TEST_OUTPUT_DIR/signal-stubs"
mkdir -p "$SIGNAL_STUB_DIR"
cp "$STUB_DIR/timeout" "$SIGNAL_STUB_DIR/timeout"
cp "$STUB_DIR/ps" "$SIGNAL_STUB_DIR/ps"
cp "$STUB_DIR/cp" "$SIGNAL_STUB_DIR/cp"
cat > "$SIGNAL_STUB_DIR/claude" << 'STUB'
#!/bin/bash
previous=""
for argument in "$@"; do
    if [ "$previous" = "--settings" ]; then
        printf '%s\n' "$argument" > "$SIGNAL_SETTINGS_PATH_LOG"
    fi
    previous="$argument"
done
printf '%s\n' "$PWD" > "$SIGNAL_SNAPSHOT_PATH_LOG"
printf '%s\n' "$$" > "$SIGNAL_CHILD_PID_LOG"
cat > /dev/null
trap '' TERM INT
kill -TERM "$GH_PR_ENRICH_CLEANUP_OWNER_PID"
while true; do :; done
STUB
chmod +x "$SIGNAL_STUB_DIR/claude"
SIGNAL_SNAPSHOT_PATH_LOG="$TEST_OUTPUT_DIR/signal-snapshot-path.txt"
SIGNAL_SETTINGS_PATH_LOG="$TEST_OUTPUT_DIR/signal-settings-path.txt"
SIGNAL_CHILD_PID_LOG="$TEST_OUTPUT_DIR/signal-child-pid.txt"
SIGNAL_CONTEXT_COPY_LOG="$TEST_OUTPUT_DIR/signal-context-copy-path.txt"
rm -f "$SIGNAL_SNAPSHOT_PATH_LOG" "$SIGNAL_SETTINGS_PATH_LOG" \
    "$SIGNAL_CHILD_PID_LOG" "$SIGNAL_CONTEXT_COPY_LOG" "$RESPONSE"
rc=0
SIGNAL_STARTED_AT=$(date +%s)
(cd "$CODE_ACCESS_REPO" && env \
    SIGNAL_SNAPSHOT_PATH_LOG="$SIGNAL_SNAPSHOT_PATH_LOG" \
    SIGNAL_SETTINGS_PATH_LOG="$SIGNAL_SETTINGS_PATH_LOG" \
    SIGNAL_CHILD_PID_LOG="$SIGNAL_CHILD_PID_LOG" \
    ANALYZER_CONTEXT_COPY_LOG="$SIGNAL_CONTEXT_COPY_LOG" \
    PS_CALLED_LOG="$PS_CALLED_LOG" \
    CLAUDE_TIMEOUT_LOG="$TEST_OUTPUT_DIR/timeout.txt" \
    PATH="$SIGNAL_STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call run_claude_analysis "$CONTEXT" "$RESPONSE" \
    >/dev/null 2>&1) || rc=$?
SIGNAL_ELAPSED=$(( $(date +%s) - SIGNAL_STARTED_AT ))
TERMINATED_SNAPSHOT=$(cat "$SIGNAL_SNAPSHOT_PATH_LOG" 2>/dev/null || echo "")
TERMINATED_SETTINGS=$(cat "$SIGNAL_SETTINGS_PATH_LOG" 2>/dev/null || echo "")
TERMINATED_CHILD=$(cat "$SIGNAL_CHILD_PID_LOG" 2>/dev/null || echo "")
TERMINATED_CONTEXT_COPY=$(tail -1 "$SIGNAL_CONTEXT_COPY_LOG" 2>/dev/null || echo "")
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "terminating a code-enabled analyzer interrupts the run"
assert_true "$([ -n "$TERMINATED_SNAPSHOT" ] && [ ! -e "$TERMINATED_SNAPSHOT" ] && echo 0 || echo 1)" \
    "TERM removes the private analyzer snapshot"
assert_true "$([ -n "$TERMINATED_SETTINGS" ] && [ ! -e "$TERMINATED_SETTINGS" ] && echo 0 || echo 1)" \
    "TERM removes the isolated Claude settings file"
assert_true "$([ -n "$TERMINATED_CONTEXT_COPY" ] && \
    [ ! -e "$TERMINATED_CONTEXT_COPY" ] && echo 0 || echo 1)" \
    "TERM removes the immutable analyzer context copy"
assert_true "$([ "$SIGNAL_ELAPSED" -lt 5 ] && echo 0 || echo 1)" \
    "TERM promptly interrupts a hung analyzer that ignores TERM"
for _attempt in $(seq 1 100); do
    [ -z "$TERMINATED_CHILD" ] || ! kill -0 "$TERMINATED_CHILD" 2>/dev/null && break
    sleep 0.02
done
assert_true "$([ -n "$TERMINATED_CHILD" ] && ! kill -0 "$TERMINATED_CHILD" 2>/dev/null && echo 0 || echo 1)" \
    "TERM reaps the analyzer descendant without leaking a child process"
assert_eq "" "$(cat "$PS_CALLED_LOG")" \
    "analyzer cancellation and janitor cleanup do not require process-table discovery"

RACE_CONTEXT="$TEST_OUTPUT_DIR/race-context.json"
cp "$CONTEXT" "$RACE_CONTEXT"
rm -f "$RESPONSE"
rc=0
CONTEXT_RACE_OUT=$(cd "$CODE_ACCESS_REPO" && env CONTEXT_MUTATION_TARGET="$RACE_CONTEXT" \
    CLAUDE_TIMEOUT_LOG="$TEST_OUTPUT_DIR/timeout.txt" PATH="$MUTATION_STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call run_claude_analysis "$RACE_CONTEXT" "$RESPONSE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "an analyzer response is rejected when its immutable context changes during the run"
assert_contains "$CONTEXT_RACE_OUT" "Analysis context changed during Claude analysis" \
    "the context-refresh race is reported explicitly"
assert_true "$([ ! -e "$RESPONSE" ] && echo 0 || echo 1)" \
    "a response produced across two context snapshots is removed"

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

for invalid_heartbeat in 0 -1 invalid; do
    assert_eq "60" \
        "$("$GH_PR_ENRICH" --test-call positive_integer_or_default \
            "$invalid_heartbeat" 60)" \
        "invalid heartbeat '$invalid_heartbeat' falls back to 60 seconds"
done
assert_eq "7" \
    "$("$GH_PR_ENRICH" --test-call positive_integer_or_default 7 60)" \
    "a positive heartbeat interval is preserved"
assert_eq "60" \
    "$("$GH_PR_ENRICH" --test-call positive_integer_or_default 86401 60 86400)" \
    "a heartbeat above the safe one-day bound falls back to 60 seconds"
assert_eq "60" \
    "$("$GH_PR_ENRICH" --test-call positive_integer_or_default \
        999999999999999999999999 60 86400)" \
    "an oversized heartbeat cannot overflow the numeric bound"
SLEEP_INTERVAL_LOG="$TEST_OUTPUT_DIR/heartbeat-sleeps.txt"
rm -f "$SLEEP_INTERVAL_LOG"
run_analysis GH_PR_ENRICH_HEARTBEAT_SECONDS=0 \
    SLEEP_INTERVAL_LOG="$SLEEP_INTERVAL_LOG"
assert_contains "$(cat "$SLEEP_INTERVAL_LOG")" "60" \
    "a zero heartbeat starts a normal 60-second wait"
assert_eq "" "$(grep -x '0' "$SLEEP_INTERVAL_LOG" || true)" \
    "a zero heartbeat cannot create a progress-loop spin"
rm -f "$SLEEP_INTERVAL_LOG"
run_analysis GH_PR_ENRICH_HEARTBEAT_SECONDS=999999999999999999999999 \
    SLEEP_INTERVAL_LOG="$SLEEP_INTERVAL_LOG"
assert_contains "$(cat "$SLEEP_INTERVAL_LOG")" "60" \
    "an oversized heartbeat starts a valid 60-second wait"
assert_eq "" \
    "$(grep -x '999999999999999999999999' "$SLEEP_INTERVAL_LOG" || true)" \
    "an oversized heartbeat never reaches sleep"
rm -f "$SLEEP_INTERVAL_LOG"
run_analysis GH_PR_ENRICH_HEARTBEAT_SECONDS=60 \
    SLEEP_INTERVAL_LOG="$SLEEP_INTERVAL_LOG" SLEEP_FAIL_INTERVAL=60 \
    CLAUDE_STUB_DELAY=0.1
assert_eq "1" "$(grep -cx '60' "$SLEEP_INTERVAL_LOG" || true)" \
    "a rejected heartbeat sleep terminates instead of spinning"

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
    (cd "$CODE_ACCESS_REPO" && env PATH="$STUB_DIR:$PATH" \
        "$GH_PR_ENRICH" --test-call resolve_code_access "$1" 2>&1) || true
}

LOCAL_HEAD=$(git -C "$CODE_ACCESS_REPO" rev-parse HEAD)

MATCHED=$(revision_state "$LOCAL_HEAD")
assert_contains "$MATCHED" "enabled" "code access is enabled when the tree is at the PR head"

echo dirty >> "$CODE_ACCESS_REPO/tracked.txt"
DIRTY=$(revision_state "$LOCAL_HEAD")
assert_contains "$DIRTY" "disabled" "automatic code access is disabled for a dirty working tree"
DIRTY_FORCED=$( (cd "$CODE_ACCESS_REPO" && env GH_PR_ENRICH_CODE_ACCESS=true \
    "$GH_PR_ENRICH" --test-call resolve_code_access "$LOCAL_HEAD" 2>&1) || true)
assert_contains "$DIRTY_FORCED" "enabled" "an explicit code-access override can expose a dirty working tree"
git -C "$CODE_ACCESS_REPO" checkout -- tracked.txt

echo 'IGNORED_SECRET=fixture' > "$CODE_ACCESS_REPO/.env"
IGNORED_DIRTY=$(revision_state "$LOCAL_HEAD")
assert_contains "$IGNORED_DIRTY" "disabled" \
    "automatic code access is disabled when ignored files exist"
IGNORED_ROOT_OUTPUT=$( (cd "$CODE_ACCESS_REPO" && \
    "$GH_PR_ENRICH" --test-call resolve_code_access "$LOCAL_HEAD" "$CODE_ACCESS_REPO" 2>&1) || true)
assert_contains "$IGNORED_ROOT_OUTPUT" "disabled" \
    "repository-root output cannot bypass ignored-file detection"
rm "$CODE_ACCESS_REPO/.env"

# A user-selected report directory may contain tracked source. Generated-file
# exclusions must never hide modifications to such files.
OUTPUT_OVERLAP_REPO="$TEST_OUTPUT_DIR/output-overlap-repo"
mkdir -p "$OUTPUT_OVERLAP_REPO/report"
(cd "$OUTPUT_OVERLAP_REPO" && git init -q . && git config user.email t@t && git config user.name t \
    && echo source > report/source.js && git add -A && git commit -qm init)
OUTPUT_OVERLAP_HEAD=$(git -C "$OUTPUT_OVERLAP_REPO" rev-parse HEAD)
echo dirty >> "$OUTPUT_OVERLAP_REPO/report/source.js"
OUTPUT_OVERLAP=$( (cd "$OUTPUT_OVERLAP_REPO" && \
    "$GH_PR_ENRICH" --test-call resolve_code_access "$OUTPUT_OVERLAP_HEAD" \
        "$OUTPUT_OVERLAP_REPO/report" 2>&1) || true)
assert_contains "$OUTPUT_OVERLAP" "disabled" \
    "an output-directory exclusion cannot hide modified tracked source"

OUTPUT_SYMLINK_REPO="$TEST_OUTPUT_DIR/output-symlink-repo"
mkdir -p "$OUTPUT_SYMLINK_REPO/report"
(cd "$OUTPUT_SYMLINK_REPO" && git init -q . && git config user.email t@t && git config user.name t \
    && echo tracked > tracked.txt && git add -A && git commit -qm init)
OUTPUT_SYMLINK_HEAD=$(git -C "$OUTPUT_SYMLINK_REPO" rev-parse HEAD)
ln -s ../tracked.txt "$OUTPUT_SYMLINK_REPO/report/analysis-context.json"
OUTPUT_SYMLINK=$( (cd "$OUTPUT_SYMLINK_REPO" && \
    "$GH_PR_ENRICH" --test-call resolve_code_access "$OUTPUT_SYMLINK_HEAD" \
        "$OUTPUT_SYMLINK_REPO/report" 2>&1) || true)
assert_contains "$OUTPUT_SYMLINK" "disabled" \
    "a generated-name symlink cannot hide behind the output allowlist"

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
assert_contains "$AHEAD" "disabled" "automatic code access is disabled when the tree is ahead of the PR head"
assert_contains "$AHEAD" "1 commit(s) ahead" "the report says how far ahead the tree is"
AHEAD_FORCED=$( (cd "$AHEAD_REPO" && env GH_PR_ENRICH_CODE_ACCESS=true \
    "$GH_PR_ENRICH" --test-call resolve_code_access "$BASE_SHA" 2>&1) || true)
assert_contains "$AHEAD_FORCED" "enabled" \
    "an explicit override can expose commits ahead of the PR head"

# An unrelated repository is not "ahead" — it is a different history entirely.
UNRELATED="$TEST_OUTPUT_DIR/unrelated-repo"
mkdir -p "$UNRELATED"
(cd "$UNRELATED" && git init -q . && git config user.email t@t && git config user.name t \
    && echo other > g.txt && git add -A && git commit -qm only)
UNRELATED_OUT=$( (cd "$UNRELATED" && "$GH_PR_ENRICH" --test-call resolve_code_access "$BASE_SHA" 2>&1) || true)
assert_contains "$UNRELATED_OUT" "disabled" "an unrelated history does not count as ahead of the PR head"

# Gitlinks hide a second mutable workspace behind one parent-tree entry. The
# bounded implementation takes the simple safe route and rejects all submodules.
SUBMODULE_SOURCE="$TEST_OUTPUT_DIR/submodule-source"
SUBMODULE_REPO="$TEST_OUTPUT_DIR/submodule-repo"
mkdir -p "$SUBMODULE_SOURCE" "$SUBMODULE_REPO"
(cd "$SUBMODULE_SOURCE" && git init -q . && git config user.email t@t && git config user.name t \
    && echo child > child.txt && git add child.txt && git commit -qm init)
(cd "$SUBMODULE_REPO" && git init -q . && git config user.email t@t && git config user.name t \
    && echo parent > parent.txt && git add parent.txt && git commit -qm init \
    && git -c protocol.file.allow=always submodule add -q "$SUBMODULE_SOURCE" module \
    && git commit -qam submodule)
SUBMODULE_PARENT_HEAD=$(git -C "$SUBMODULE_REPO" rev-parse HEAD)
echo dirty >> "$SUBMODULE_REPO/module/child.txt"
assert_eq "$SUBMODULE_PARENT_HEAD" "$(git -C "$SUBMODULE_REPO" rev-parse HEAD)" \
    "dirty submodule contents leave the parent gitlink revision unchanged"
rc=0
(cd "$SUBMODULE_REPO" && "$GH_PR_ENRICH" --test-call \
    code_access_workspace_fingerprint "$SUBMODULE_REPO/report" >/dev/null 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a repository containing a gitlink fails closed for code-enabled analysis"

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
(cd "$CODE_ACCESS_REPO" && "$GH_PR_ENRICH" --test-call build_claude_context "$REV_DIR" false >/dev/null 2>&1) || true

assert_jq "$REV_DIR/claude-context.json" '.coverage.code_access != null' \
    "coverage records the code-access state"
assert_jq "$REV_DIR/claude-context.json" '.coverage.code_access.pr_head_sha != null' \
    "coverage records the PR head revision"
assert_jq "$REV_DIR/claude-context.json" '.coverage.code_access.revision_matches == true' \
    "coverage records whether the inspected tree matches the PR"
assert_jq "$REV_DIR/claude-context.json" \
    '(.coverage.code_access.workspace_fingerprint // "") | startswith("sha256:")' \
    "coverage fingerprints the exact workspace granted to the analyzer"

# ---------------------------------------------------------------------------
# Failure paths must be diagnosable, and must not leak shell internals
# ---------------------------------------------------------------------------
FAIL_STUBS="$TEST_OUTPUT_DIR/fail-stubs"
mkdir -p "$FAIL_STUBS"
cp "$STUB_DIR/timeout" "$FAIL_STUBS/timeout"
cp "$STUB_DIR/ps" "$FAIL_STUBS/ps"

# The wrapper owns both the direct Claude child and the timeout watcher. A real
# deadline kills and reaps a Claude process that ignores cooperative shutdown.
TIMEOUT_CHILD_PID_LOG="$TEST_OUTPUT_DIR/timeout-child-pid.txt"
cat > "$FAIL_STUBS/claude" << 'STUB'
#!/bin/bash
printf '%s\n' "$$" > "$TIMEOUT_CHILD_PID_LOG"
cat > /dev/null
trap '' TERM INT
while true; do :; done
STUB
chmod +x "$FAIL_STUBS/claude"
rc=0
REAL_TIMEOUT_OUT=$(cd "$CODE_ACCESS_REPO" && env CLAUDE_TIMEOUT=1 \
    TIMEOUT_CHILD_PID_LOG="$TIMEOUT_CHILD_PID_LOG" PS_CALLED_LOG="$PS_CALLED_LOG" \
    PATH="$FAIL_STUBS:$PATH" "$GH_PR_ENRICH" --test-call run_claude_analysis \
    "$REV_DIR/analysis-context.json" "$TEST_OUTPUT_DIR/real-timeout.json" 2>&1) || rc=$?
TIMED_OUT_CHILD=$(cat "$TIMEOUT_CHILD_PID_LOG" 2>/dev/null || echo "")
assert_eq "137" "$rc" "the internal timeout preserves the killed-analyzer exit status"
assert_contains "$REAL_TIMEOUT_OUT" "timed out after 1s" \
    "the internal timeout reports the configured deadline"
for _attempt in $(seq 1 100); do
    [ -z "$TIMED_OUT_CHILD" ] || ! kill -0 "$TIMED_OUT_CHILD" 2>/dev/null && break
    sleep 0.01
done
assert_true "$([ -n "$TIMED_OUT_CHILD" ] && ! kill -0 "$TIMED_OUT_CHILD" 2>/dev/null && echo 0 || echo 1)" \
    "the timeout wrapper reaps its direct Claude child"

# Analyzer killed by a signal (what a real timeout looks like)
cat > "$FAIL_STUBS/claude" << 'STUB'
#!/bin/bash
cat > /dev/null
kill -9 $$
STUB
chmod +x "$FAIL_STUBS/claude"

KILLED_OUT=$(cd "$CODE_ACCESS_REPO" && env CLAUDE_ARG_LOG="$ARG_LOG" CLAUDE_TIMEOUT_LOG="$TEST_OUTPUT_DIR/timeout.txt" \
    PATH="$FAIL_STUBS:$PATH" "$GH_PR_ENRICH" --test-call run_claude_analysis \
    "$REV_DIR/analysis-context.json" "$TEST_OUTPUT_DIR/killed.json" 2>&1 || true)

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
FAILED_OUT=$(cd "$CODE_ACCESS_REPO" && env CLAUDE_ARG_LOG="$ARG_LOG" CLAUDE_TIMEOUT_LOG="$TEST_OUTPUT_DIR/timeout.txt" \
    PATH="$FAIL_STUBS:$PATH" "$GH_PR_ENRICH" --test-call run_claude_analysis \
    "$REV_DIR/analysis-context.json" "$TEST_OUTPUT_DIR/failed.json" 2>&1) || rc=$?

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

SAST_SNAPSHOT_CWD_LOG="$TEST_OUTPUT_DIR/semgrep-snapshot-cwd.log"
(cd "$WORKSPACE" && env PATH="$STUB_DIR:$PATH" \
    SEMGREP_CWD_LOG="$SAST_SNAPSHOT_CWD_LOG" \
    "$GH_PR_ENRICH" --test-call collect_sast_findings \
    "reports" >/dev/null 2>&1) || true
SAST_FILE="$SAST_DIR/sast-findings.json"

assert_jq_eq "$SAST_FILE" 'length' "1" "semgrep findings are collected"
assert_jq "$SAST_FILE" '.[0].path == "src/retry.js"' "finding carries its path"
assert_jq "$SAST_FILE" '.[0].line == 12' "finding carries its line"
assert_jq "$SAST_FILE" '.[0].severity == "ERROR"' "finding carries its severity"
assert_jq "$SAST_FILE" '.[0].check_id | contains("unsafe-exec")' "finding carries its rule id"
assert_jq "$SAST_FILE" '.[0].message | contains("unsafe exec")' "finding carries its message"
SAST_SNAPSHOT_CWD=$(cat "$SAST_SNAPSHOT_CWD_LOG" 2>/dev/null || echo "")
assert_true "$([ -n "$SAST_SNAPSHOT_CWD" ] && \
    [ "$SAST_SNAPSHOT_CWD" != "$WORKSPACE" ] && echo 0 || echo 1)" \
    "semgrep runs from a private immutable workspace snapshot"
assert_true "$([ ! -d "$SAST_SNAPSHOT_CWD" ] && echo 0 || echo 1)" \
    "a successful semgrep scan removes its immutable workspace snapshot"
assert_jq "$SAST_DIR/sast-status.json" \
    '.status == "completed" and .workspace_source == "immutable_snapshot" and
     (.workspace_fingerprint | startswith("sha256:"))' \
    "completed SAST provenance binds the immutable workspace fingerprint"

# A zero-exit scanner envelope is not automatically a clean result. Semgrep's
# root must explicitly contain a results array before projection can complete.
SAST_ENVELOPE_STUBS="$TEST_OUTPUT_DIR/semgrep-envelope-stubs"
mkdir -p "$SAST_ENVELOPE_STUBS"
cat > "$SAST_ENVELOPE_STUBS/semgrep" << 'STUB'
#!/bin/bash
case "$SEMGREP_ENVELOPE" in
    missing) printf '%s\n' '{}' ;;
    wrong-type) printf '%s\n' '{"results":{}}' ;;
    *) exit 2 ;;
esac
STUB
chmod +x "$SAST_ENVELOPE_STUBS/semgrep"
for SAST_ENVELOPE in missing wrong-type; do
    SAST_ENVELOPE_DIR="$WORKSPACE/envelope-$SAST_ENVELOPE"
    mkdir -p "$SAST_ENVELOPE_DIR"
    cp "$SAST_DIR/pr-summary.json" "$SAST_ENVELOPE_DIR/pr-summary.json"
    (cd "$WORKSPACE" && env PATH="$SAST_ENVELOPE_STUBS:$PATH" \
        GH_PR_ENRICH_CODE_ACCESS=true \
        SEMGREP_ENVELOPE="$SAST_ENVELOPE" \
        "$GH_PR_ENRICH" --test-call collect_sast_findings \
        "envelope-$SAST_ENVELOPE" >/dev/null 2>&1)
    assert_jq_eq "$SAST_ENVELOPE_DIR/sast-findings.json" 'length' "0" \
        "Semgrep $SAST_ENVELOPE envelope cannot become a false-clean finding set"
    assert_jq "$SAST_ENVELOPE_DIR/sast-status.json" \
        '.status == "failed" and
         (.reason | contains("object with a results array"))' \
        "Semgrep $SAST_ENVELOPE envelope records failed scan coverage"
done

# Freeze before scanning so an original-tree mutate/revert ABA cannot change
# what Semgrep reads. The scanner blocks between two reads while the test
# changes and restores the live checkout.
SAST_ABA_REPORTS="$WORKSPACE/aba-reports"
SAST_ABA_STUBS="$TEST_OUTPUT_DIR/semgrep-aba-stubs"
SAST_ABA_READY="$TEST_OUTPUT_DIR/semgrep-aba.ready"
SAST_ABA_RELEASE="$TEST_OUTPUT_DIR/semgrep-aba.release"
SAST_ABA_READ_LOG="$TEST_OUTPUT_DIR/semgrep-aba-reads.log"
SAST_ABA_CWD_LOG="$TEST_OUTPUT_DIR/semgrep-aba-cwd.log"
mkdir -p "$SAST_ABA_REPORTS" "$SAST_ABA_STUBS"
cp "$SAST_DIR/pr-summary.json" "$SAST_ABA_REPORTS/pr-summary.json"
rm -f "$SAST_ABA_READY" "$SAST_ABA_RELEASE"
: > "$SAST_ABA_READ_LOG"
cat > "$SAST_ABA_STUBS/semgrep" << 'STUB'
#!/bin/bash
pwd > "$SEMGREP_CWD_LOG"
cat ./src/retry.js >> "$SEMGREP_READ_LOG"
: > "$SEMGREP_READY_FILE"
while [ ! -f "$SEMGREP_RELEASE_FILE" ]; do /bin/sleep 0.01; done
cat ./src/retry.js >> "$SEMGREP_READ_LOG"
echo '{"results":[{"check_id":"snapshot.aba","path":"./src/retry.js","start":{"line":1},"extra":{"severity":"INFO","message":"stable snapshot","metadata":{}}}],"errors":[]}'
STUB
chmod +x "$SAST_ABA_STUBS/semgrep"
(
    cd "$WORKSPACE"
    env PATH="$SAST_ABA_STUBS:$STUB_DIR:$PATH" \
        GH_PR_ENRICH_CODE_ACCESS=true \
        SEMGREP_CWD_LOG="$SAST_ABA_CWD_LOG" \
        SEMGREP_READ_LOG="$SAST_ABA_READ_LOG" \
        SEMGREP_READY_FILE="$SAST_ABA_READY" \
        SEMGREP_RELEASE_FILE="$SAST_ABA_RELEASE" \
        "$GH_PR_ENRICH" --test-call collect_sast_findings "aba-reports"
) >/dev/null 2>&1 &
SAST_ABA_CLI_PID=$!
for _ in {1..200}; do
    [ ! -f "$SAST_ABA_READY" ] || break
    /bin/sleep 0.05
done
assert_true "$([ -f "$SAST_ABA_READY" ] && echo 0 || echo 1)" \
    "the immutable Semgrep fixture reaches its between-read barrier"
printf 'mutated live bytes\n' > "$WORKSPACE/src/retry.js"
printf 'const x = 1;\n' > "$WORKSPACE/src/retry.js"
: > "$SAST_ABA_RELEASE"
wait "$SAST_ABA_CLI_PID"
assert_eq $'const x = 1;\nconst x = 1;' \
    "$(cat "$SAST_ABA_READ_LOG")" \
    "semgrep reads stable snapshot bytes across a live-checkout ABA mutation"
SAST_ABA_SNAPSHOT=$(cat "$SAST_ABA_CWD_LOG" 2>/dev/null || echo "")
assert_true "$([ -n "$SAST_ABA_SNAPSHOT" ] && \
    [ "$SAST_ABA_SNAPSHOT" != "$WORKSPACE" ] && echo 0 || echo 1)" \
    "the ABA scanner never runs from the mutable original checkout"
assert_true "$([ ! -d "$SAST_ABA_SNAPSHOT" ] && echo 0 || echo 1)" \
    "the ABA scan removes its immutable snapshot after completion"
assert_jq "$SAST_ABA_REPORTS/sast-findings.json" \
    '.[0].path == "src/retry.js" and .[0].message == "stable snapshot"' \
    "snapshot-relative Semgrep paths normalize back to repository paths"

# The context builder is a separate trust boundary. A scan that completed for
# one immutable workspace must not enter a context built after the live
# workspace changes, even when explicit code access permits inspecting a dirty
# tree.
printf '[]\n' > "$SAST_ABA_REPORTS/issue-comments.json"
printf '[]\n' > "$SAST_ABA_REPORTS/unresolved-threads.json"
printf 'changed after scan\n' > "$WORKSPACE/src/retry.js"
(
    cd "$WORKSPACE"
    GH_PR_ENRICH_CODE_ACCESS=true "$GH_PR_ENRICH" --test-call \
        build_claude_context "aba-reports" false true >/dev/null
)
assert_jq_eq "$SAST_ABA_REPORTS/claude-context.json" \
    '.sast_findings | length' "0" \
    "context construction discards SAST findings from a different workspace fingerprint"
assert_jq "$SAST_ABA_REPORTS/claude-context.json" \
    '.coverage.sast.status == "failed" and
     (.coverage.sast.reason | contains("does not match the analysis context workspace fingerprint")) and
     .coverage.sast.findings == 0' \
    "context coverage names a post-scan workspace provenance mismatch"
printf 'const x = 1;\n' > "$WORKSPACE/src/retry.js"

# Stock macOS has no GNU timeout. The portable owned watchdog must terminate and
# reap a stalled scanner without invoking any timeout binary on PATH.
WATCHDOG_REPORTS="$WORKSPACE/watchdog-reports"
WATCHDOG_STUBS="$TEST_OUTPUT_DIR/semgrep-watchdog-stubs"
WATCHDOG_PID_LOG="$TEST_OUTPUT_DIR/semgrep-watchdog.pid"
WATCHDOG_CHILD_PID_LOG="$TEST_OUTPUT_DIR/semgrep-watchdog-child.pid"
WATCHDOG_CWD_LOG="$TEST_OUTPUT_DIR/semgrep-watchdog-cwd.log"
WATCHDOG_TIMEOUT_LOG="$TEST_OUTPUT_DIR/semgrep-timeout-command.log"
mkdir -p "$WATCHDOG_REPORTS" "$WATCHDOG_STUBS"
cp "$SAST_DIR/pr-summary.json" "$WATCHDOG_REPORTS/pr-summary.json"
: > "$WATCHDOG_TIMEOUT_LOG"
cat > "$WATCHDOG_STUBS/semgrep" << 'STUB'
#!/bin/bash
printf '%s\n' "$$" > "$SEMGREP_PID_LOG"
[ -z "${SEMGREP_CWD_LOG:-}" ] || pwd > "$SEMGREP_CWD_LOG"
trap '' TERM INT
"$SEMGREP_CHILD_STUB" &
child_pid=$!
printf '%s\n' "$child_pid" > "$SEMGREP_CHILD_PID_LOG"
wait "$child_pid"
STUB
chmod +x "$WATCHDOG_STUBS/semgrep"
cat > "$WATCHDOG_STUBS/semgrep-child" << 'STUB'
#!/bin/bash
trap '' TERM INT
while :; do :; done
STUB
chmod +x "$WATCHDOG_STUBS/semgrep-child"
cat > "$WATCHDOG_STUBS/timeout" << 'STUB'
#!/bin/bash
printf 'invoked\n' >> "$SEMGREP_GNU_TIMEOUT_LOG"
exit 99
STUB
chmod +x "$WATCHDOG_STUBS/timeout"

SECONDS=0
WATCHDOG_OUT=$( (cd "$WORKSPACE" && env \
    PATH="$WATCHDOG_STUBS:$STUB_DIR:$PATH" \
    GH_PR_ENRICH_CODE_ACCESS=true GH_PR_ENRICH_SEMGREP_TIMEOUT=1 \
    SEMGREP_PID_LOG="$WATCHDOG_PID_LOG" \
    SEMGREP_CHILD_PID_LOG="$WATCHDOG_CHILD_PID_LOG" \
    SEMGREP_CHILD_STUB="$WATCHDOG_STUBS/semgrep-child" \
    SEMGREP_CWD_LOG="$WATCHDOG_CWD_LOG" \
    SEMGREP_GNU_TIMEOUT_LOG="$WATCHDOG_TIMEOUT_LOG" \
    "$GH_PR_ENRICH" --test-call collect_sast_findings \
    "watchdog-reports" 2>&1) || true)
WATCHDOG_ELAPSED=$SECONDS
assert_true "$([ "$WATCHDOG_ELAPSED" -ge 1 ] && [ "$WATCHDOG_ELAPSED" -lt 8 ] && echo 0 || echo 1)" \
    "the portable Semgrep watchdog enforces the configured timeout without spinning"
assert_true "$([ ! -s "$WATCHDOG_TIMEOUT_LOG" ] && echo 0 || echo 1)" \
    "the portable Semgrep watchdog does not invoke GNU timeout even when one is present"
assert_jq "$WATCHDOG_REPORTS/sast-status.json" '.status == "failed"' \
    "a watchdog-terminated Semgrep scan is recorded as failed coverage"
WATCHDOG_SEMGREP_PID=$(cat "$WATCHDOG_PID_LOG" 2>/dev/null || echo "")
WATCHDOG_CHILD_PID=$(cat "$WATCHDOG_CHILD_PID_LOG" 2>/dev/null || echo "")
for _ in 1 2 3 4 5 6 7 8 9 10; do
    scanner_alive=false
    child_alive=false
    [ -z "$WATCHDOG_SEMGREP_PID" ] || ! kill -0 "$WATCHDOG_SEMGREP_PID" 2>/dev/null || scanner_alive=true
    [ -z "$WATCHDOG_CHILD_PID" ] || ! kill -0 "$WATCHDOG_CHILD_PID" 2>/dev/null || child_alive=true
    [ "$scanner_alive" = true ] || [ "$child_alive" = true ] || break
    /bin/sleep 0.05
done
assert_true "$([ -n "$WATCHDOG_SEMGREP_PID" ] && [ "$scanner_alive" = false ] && echo 0 || echo 1)" \
    "the portable Semgrep watchdog reaps the stalled scanner"
assert_true "$([ -n "$WATCHDOG_CHILD_PID" ] && [ "$child_alive" = false ] && echo 0 || echo 1)" \
    "the portable Semgrep watchdog terminates scanner descendants"
WATCHDOG_SNAPSHOT=$(cat "$WATCHDOG_CWD_LOG" 2>/dev/null || echo "")
assert_true "$([ -n "$WATCHDOG_SNAPSHOT" ] && [ ! -d "$WATCHDOG_SNAPSHOT" ] && echo 0 || echo 1)" \
    "a timed-out Semgrep scan removes its immutable snapshot"
assert_contains "$WATCHDOG_OUT" "semgrep failed" \
    "a watchdog timeout is reported as a failed Semgrep pre-pass"

# Sending TERM only to the top-level CLI must propagate through the owned
# wrapper and scanner process group instead of leaving a long-timeout orphan.
CANCEL_REPORTS="$WORKSPACE/cancel-reports"
CANCEL_SCANNER_PID_LOG="$TEST_OUTPUT_DIR/semgrep-cancel.pid"
CANCEL_CHILD_PID_LOG="$TEST_OUTPUT_DIR/semgrep-cancel-child.pid"
CANCEL_CWD_LOG="$TEST_OUTPUT_DIR/semgrep-cancel-cwd.log"
mkdir -p "$CANCEL_REPORTS"
cp "$SAST_DIR/pr-summary.json" "$CANCEL_REPORTS/pr-summary.json"
(
    cd "$WORKSPACE"
    exec env PATH="$WATCHDOG_STUBS:$STUB_DIR:$PATH" \
        GH_PR_ENRICH_CODE_ACCESS=true GH_PR_ENRICH_SEMGREP_TIMEOUT=3600 \
        SEMGREP_PID_LOG="$CANCEL_SCANNER_PID_LOG" \
        SEMGREP_CHILD_PID_LOG="$CANCEL_CHILD_PID_LOG" \
        SEMGREP_CHILD_STUB="$WATCHDOG_STUBS/semgrep-child" \
        SEMGREP_CWD_LOG="$CANCEL_CWD_LOG" \
        SEMGREP_GNU_TIMEOUT_LOG="$WATCHDOG_TIMEOUT_LOG" \
        "$GH_PR_ENRICH" --test-call collect_sast_findings "cancel-reports"
) > "$TEST_OUTPUT_DIR/semgrep-cancel.out" 2>&1 &
CANCEL_CLI_PID=$!
for _ in {1..200}; do
    [ ! -s "$CANCEL_SCANNER_PID_LOG" ] || [ ! -s "$CANCEL_CHILD_PID_LOG" ] || break
    /bin/sleep 0.05
done
assert_true "$([ -s "$CANCEL_SCANNER_PID_LOG" ] && [ -s "$CANCEL_CHILD_PID_LOG" ] && echo 0 || echo 1)" \
    "the cancellation fixture starts a scanner and descendant"
SECONDS=0
kill -TERM "$CANCEL_CLI_PID"
CANCEL_RC=0
wait "$CANCEL_CLI_PID" || CANCEL_RC=$?
CANCEL_ELAPSED=$SECONDS
CANCEL_SCANNER_PID=$(cat "$CANCEL_SCANNER_PID_LOG" 2>/dev/null || echo "")
CANCEL_CHILD_PID=$(cat "$CANCEL_CHILD_PID_LOG" 2>/dev/null || echo "")
for _ in 1 2 3 4 5 6 7 8 9 10; do
    cancel_scanner_alive=false
    cancel_child_alive=false
    [ -z "$CANCEL_SCANNER_PID" ] || ! kill -0 "$CANCEL_SCANNER_PID" 2>/dev/null || cancel_scanner_alive=true
    [ -z "$CANCEL_CHILD_PID" ] || ! kill -0 "$CANCEL_CHILD_PID" 2>/dev/null || cancel_child_alive=true
    [ "$cancel_scanner_alive" = true ] || [ "$cancel_child_alive" = true ] || break
    /bin/sleep 0.05
done
assert_true "$([ "$CANCEL_RC" -ne 0 ] && [ "$CANCEL_ELAPSED" -lt 8 ] && echo 0 || echo 1)" \
    "TERM sent only to the CLI promptly cancels the long Semgrep run"
assert_true "$([ -n "$CANCEL_SCANNER_PID" ] && [ "$cancel_scanner_alive" = false ] && echo 0 || echo 1)" \
    "CLI cancellation reaps the owned Semgrep scanner"
assert_true "$([ -n "$CANCEL_CHILD_PID" ] && [ "$cancel_child_alive" = false ] && echo 0 || echo 1)" \
    "CLI cancellation terminates Semgrep descendants"
CANCEL_SNAPSHOT=$(cat "$CANCEL_CWD_LOG" 2>/dev/null || echo "")
assert_true "$([ -n "$CANCEL_SNAPSHOT" ] && [ ! -d "$CANCEL_SNAPSHOT" ] && echo 0 || echo 1)" \
    "CLI cancellation removes the immutable Semgrep snapshot"

# Timeout input is bounded before it reaches sleep. Invalid explicit values use
# the documented safe default, while the upper boundary remains accepted.
TIMEOUT_REPORTS="$WORKSPACE/timeout-reports"
TIMEOUT_STUBS="$TEST_OUTPUT_DIR/semgrep-timeout-stubs"
TIMEOUT_VALUE_LOG="$TEST_OUTPUT_DIR/semgrep-timeout-values.log"
mkdir -p "$TIMEOUT_REPORTS" "$TIMEOUT_STUBS"
cp "$SAST_DIR/pr-summary.json" "$TIMEOUT_REPORTS/pr-summary.json"
: > "$TIMEOUT_VALUE_LOG"
cat > "$TIMEOUT_STUBS/semgrep" << 'STUB'
#!/bin/bash
if [ -n "${WAIT_FOR_WATCHDOG_PID_LOG:-}" ]; then
    attempts=0
    while [ ! -s "$WAIT_FOR_WATCHDOG_PID_LOG" ] && [ "$attempts" -lt 100 ]; do
        /bin/sleep 0.01
        attempts=$((attempts + 1))
    done
fi
printf '%s\n' "$GH_PR_ENRICH_SEMGREP_TIMEOUT_SECONDS" >> "$SEMGREP_TIMEOUT_VALUE_LOG"
echo '{"results": [], "errors": []}'
STUB
chmod +x "$TIMEOUT_STUBS/semgrep"

for INVALID_TIMEOUT in nope 0 -1 86401 999999999999999999999999999999; do
    TIMEOUT_OUT=$( (cd "$WORKSPACE" && env \
        PATH="$TIMEOUT_STUBS:$STUB_DIR:$PATH" \
        GH_PR_ENRICH_CODE_ACCESS=true \
        GH_PR_ENRICH_SEMGREP_TIMEOUT="$INVALID_TIMEOUT" \
        SEMGREP_TIMEOUT_VALUE_LOG="$TIMEOUT_VALUE_LOG" \
        "$GH_PR_ENRICH" --test-call collect_sast_findings \
        "timeout-reports" 2>&1) || true)
    assert_eq "180" "$(tail -n 1 "$TIMEOUT_VALUE_LOG")" \
        "invalid Semgrep timeout '$INVALID_TIMEOUT' uses the safe default"
    assert_contains "$TIMEOUT_OUT" "GH_PR_ENRICH_SEMGREP_TIMEOUT" \
        "invalid Semgrep timeout '$INVALID_TIMEOUT' is reported by name"
done

(cd "$WORKSPACE" && env PATH="$TIMEOUT_STUBS:$STUB_DIR:$PATH" \
    GH_PR_ENRICH_CODE_ACCESS=true GH_PR_ENRICH_SEMGREP_TIMEOUT=86400 \
    SEMGREP_TIMEOUT_VALUE_LOG="$TIMEOUT_VALUE_LOG" \
    "$GH_PR_ENRICH" --test-call collect_sast_findings \
    "timeout-reports" >/dev/null 2>&1)
assert_eq "86400" "$(tail -n 1 "$TIMEOUT_VALUE_LOG")" \
    "the maximum supported Semgrep timeout reaches the owned watchdog unchanged"

FAST_WATCHDOG_PID_LOG="$TEST_OUTPUT_DIR/fast-semgrep-watchdog.pid"
(cd "$WORKSPACE" && env PATH="$TIMEOUT_STUBS:$STUB_DIR:$PATH" \
    GH_PR_ENRICH_CODE_ACCESS=true GH_PR_ENRICH_SEMGREP_TIMEOUT=5 \
    SEMGREP_TIMEOUT_VALUE_LOG="$TIMEOUT_VALUE_LOG" \
    SLEEP_PID_LOG="$FAST_WATCHDOG_PID_LOG" \
    WAIT_FOR_WATCHDOG_PID_LOG="$FAST_WATCHDOG_PID_LOG" \
    "$GH_PR_ENRICH" --test-call collect_sast_findings \
    "timeout-reports" >/dev/null 2>&1)
FAST_WATCHDOG_PID=$(cat "$FAST_WATCHDOG_PID_LOG" 2>/dev/null || echo "")
assert_true "$([ -n "$FAST_WATCHDOG_PID" ] && echo 0 || echo 1)" \
    "a fast Semgrep run starts an owned timeout watcher"
if [ -n "$FAST_WATCHDOG_PID" ] && kill -0 "$FAST_WATCHDOG_PID" 2>/dev/null; then
    fail "a fast Semgrep run cancels and reaps its timeout watcher" \
        "watcher sleep process $FAST_WATCHDOG_PID is still alive"
else
    pass "a fast Semgrep run cancels and reaps its timeout watcher"
fi

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
assert_jq "$SAST_DIR2/sast-status.json" '.status == "skipped" and .requested == true' \
    "missing semgrep is recorded as skipped coverage, not a clean completed scan"

# A successful gh exit with no bytes is not diff coverage. This occurs for
# permission/binary edge cases and must not render as included 0 of 0 files.
EMPTY_DIFF_DIR="$TEST_OUTPUT_DIR/empty-diff"
EMPTY_DIFF_STUBS="$EMPTY_DIFF_DIR/stubs"
mkdir -p "$EMPTY_DIFF_DIR" "$EMPTY_DIFF_STUBS"
cat > "$EMPTY_DIFF_STUBS/gh" << 'STUB'
#!/bin/bash
[ "$1 $2" = "pr diff" ] && exit 0
exit 1
STUB
chmod +x "$EMPTY_DIFF_STUBS/gh"
cat > "$EMPTY_DIFF_DIR/pr-summary.json" << 'EOF'
{"changedFiles":2,"files":[{"path":"a.js"},{"path":"b.js"}]}
EOF
PATH="$EMPTY_DIFF_STUBS:$PATH" \
    "$GH_PR_ENRICH" --test-call fetch_pr_diff "$EMPTY_DIFF_DIR" 1 >/dev/null 2>&1 || true
assert_jq "$EMPTY_DIFF_DIR/diff-status.json" '.requested == true and .status == "failed"' \
    "an empty successful gh diff is recorded as failed coverage"
assert_jq_eq "$EMPTY_DIFF_DIR/pr-diff.json" '.file_diffs | length' "0" \
    "an empty successful gh diff does not fabricate file coverage"

FORGED_DIFF_DIR="$TEST_OUTPUT_DIR/forged-diff-marker"
FORGED_DIFF_STUBS="$FORGED_DIFF_DIR/stubs"
mkdir -p "$FORGED_DIFF_DIR" "$FORGED_DIFF_STUBS"
cat > "$FORGED_DIFF_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr diff" ]; then
    cat << 'DIFF'
diff --git a/doc.txt b/doc.txt
--- a/doc.txt
+++ b/doc.txt
@@ -0,0 +1 @@
+example: diff --git a/fake b/fake
DIFF
    exit 0
fi
exit 1
STUB
chmod +x "$FORGED_DIFF_STUBS/gh"
echo '{"changedFiles":1,"files":[{"path":"doc.txt"}]}' > "$FORGED_DIFF_DIR/pr-summary.json"
PATH="$FORGED_DIFF_STUBS:$PATH" \
    "$GH_PR_ENRICH" --test-call fetch_pr_diff "$FORGED_DIFF_DIR" 1 >/dev/null 2>&1 || true
assert_jq_eq "$FORGED_DIFF_DIR/pr-diff.json" '.file_diffs | length' "1" \
    "patch content containing diff --git cannot fabricate another changed file"
assert_jq "$FORGED_DIFF_DIR/diff-status.json" '.status == "completed"' \
    "line-anchored diff parsing preserves valid one-file coverage"

suite_end
