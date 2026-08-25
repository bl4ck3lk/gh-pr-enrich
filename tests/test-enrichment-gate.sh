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
    "pr diff")
        printf 'diff --git a/a.js b/a.js\n--- a/a.js\n+++ b/a.js\n@@ -0,0 +1 @@\n+const x = 1;\n'
        exit 0
        ;;
esac
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    case "$*" in
        *closingIssuesReferences*) echo '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' ;;
        *) cat "$FIXTURE_DIR/threads.json" ;;
    esac
    exit 0
fi
if [ "$1" = "api" ]; then
    case "$*" in
        *issues/*/comments*)
            if [ -n "${CLAUDE_DISCUSSION_DRIFT_MARKER:-}" ] && \
               [ -e "$CLAUDE_DISCUSSION_DRIFT_MARKER" ]; then
                jq '. + [{id:99,body:"new same-head comment",user:{login:"reviewer"},
                    created_at:"2026-01-02T00:00:00Z",updated_at:"2026-01-02T00:00:00Z",
                    html_url:"https://github.com/o/r/pull/1#issuecomment-99"}]' \
                    "$FIXTURE_DIR/issue-comments.json"
            else
                cat "$FIXTURE_DIR/issue-comments.json"
            fi
            ;;
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
[ -z "${CLAUDE_DISCUSSION_DRIFT_MARKER:-}" ] || \
    : > "$CLAUDE_DISCUSSION_DRIFT_MARKER"
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

THREAD_JSON='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRRT_open","isResolved":false,"isOutdated":false,"path":"a.js","line":1,
   "comments":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"c","databaseId":1,"body":"needs a guard","author":{"login":"rev"},"createdAt":"2026-01-01T00:00:00Z","url":"https://github.com/o/r/pull/1#discussion_r1"}]}}
]}}}}}'
NO_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
# Raw GitHub REST shape: the script maps .user.login itself.
ONE_COMMENT='[{"id":1,"body":"CI failed on lint","user":null,"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","html_url":"https://github.com/o/r/pull/1#issuecomment-1"}]'

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
        CLAUDE_DISCUSSION_DRIFT_MARKER="${CLAUDE_DISCUSSION_DRIFT_MARKER:-}" \
        PATH="$STUB_DIR:$PATH" \
        "$GH_PR_ENRICH" 1 --enrich --diff --output-dir "$out" 2>&1 || true
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
assert_jq "$TEST_OUTPUT_DIR/comments-only/report/issue-comments.json" \
    '.[0].user == ""' \
    "a deleted GitHub comment author is retained with an empty normalized identity"

# A same-head discussion change while Claude is running invalidates the result.
# The head remains abc123; only the issue-comment snapshot changes after the
# analyzer has consumed its captured context.
CLAUDE_DISCUSSION_DRIFT_MARKER="$TEST_OUTPUT_DIR/discussion-drift-fired"
OUT=$(run_scenario "discussion-drift" "$NO_THREADS" "$ONE_COMMENT")
assert_true "$([ -e "$CLAUDE_DISCUSSION_DRIFT_MARKER" ] && echo 0 || echo 1)" \
    "the same-head drift fixture changes discussion state after Claude runs"
assert_contains "$OUT" "discussion state changed" \
    "same-head discussion drift rejects the Claude response"
assert_true "$([ ! -e "$TEST_OUTPUT_DIR/discussion-drift/report/claude-analysis.json" ] && \
    [ ! -e "$TEST_OUTPUT_DIR/discussion-drift/report/analysis.json" ] && echo 0 || echo 1)" \
    "same-head discussion drift publishes no analyzer or selected artifact"
unset CLAUDE_DISCUSSION_DRIFT_MARKER

# Watch integration: the first poll simultaneously replaces an issue-comment
# ID, adds another issue comment, and deletes an inline comment. Total comments
# stay at three, so count-only or net-delta logic misses the change. The first
# analyzer response is unusable even though the nested command exits zero; a
# planted analysis.md must not make that attempt look successful. The retained
# baseline drives one retry, whose fresh selected analysis advances the state.
WATCH_CASE="$TEST_OUTPUT_DIR/watch-transaction"
WATCH_STUB_DIR="$WATCH_CASE/stubs"
WATCH_WORK_DIR="$WATCH_CASE/work"
WATCH_POLL_FILE="$WATCH_CASE/poll.txt"
WATCH_SLEEP_COUNT_FILE="$WATCH_CASE/sleep-count.txt"
WATCH_CLAUDE_ATTEMPT_FILE="$WATCH_CASE/claude-attempt.txt"
WATCH_CLAUDE_LOG="$WATCH_CASE/claude.log"
mkdir -p "$WATCH_STUB_DIR" "$WATCH_WORK_DIR/.reports/pr-reviews/pr-1"
printf 'stale report\n' > "$WATCH_WORK_DIR/.reports/pr-reviews/pr-1/analysis.md"
printf '0\n' > "$WATCH_POLL_FILE"
printf '0\n' > "$WATCH_SLEEP_COUNT_FILE"

cat > "$WATCH_STUB_DIR/sleep" << 'STUB'
#!/bin/bash
if [ -n "${WATCH_POLL_FILE:-}" ] && [ "$1" = "60" ]; then
    count=$(cat "$WATCH_SLEEP_COUNT_FILE")
    count=$((count + 1))
    printf '%s\n' "$count" > "$WATCH_SLEEP_COUNT_FILE"
    if [ "$count" -le "${WATCH_SLEEP_LIMIT:-3}" ]; then
        printf '%s\n' "$count" > "$WATCH_POLL_FILE"
        exit 0
    fi
    kill -TERM "$PPID"
    exit 0
fi
exec /bin/sleep "$@"
STUB
chmod +x "$WATCH_STUB_DIR/sleep"

cat > "$WATCH_STUB_DIR/gh" << 'STUB'
#!/bin/bash
poll=$(cat "$WATCH_POLL_FILE" 2>/dev/null || echo 0)
summary='{"number":1,"title":"t","body":"b","author":{"login":"u"},"state":"OPEN","url":"https://github.com/o/r/pull/1","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z","mergeable":"MERGEABLE","isDraft":false,"headRefOid":"abc123","additions":1,"deletions":0,"changedFiles":1,"files":[{"path":"a.js","additions":1,"deletions":0}],"commits":[],"labels":[],"assignees":[],"reviews":[]}'
case "$1 $2" in
    "repo view")
        case "$*" in
            *nameWithOwner,visibility*) echo '{"nameWithOwner":"o/r","visibility":"PUBLIC"}' ;;
            *visibility*) echo 'PUBLIC' ;;
            *) echo 'o/r' ;;
        esac
        exit 0
        ;;
    "pr view")
        printf '%s\n' "$summary"
        exit 0
        ;;
    "pr checks") echo '[]'; exit 0 ;;
    "pr diff")
        printf 'diff --git a/a.js b/a.js\n--- a/a.js\n+++ b/a.js\n@@ -0,0 +1 @@\n+const x = 1;\n'
        exit 0
        ;;
esac
if [ "$1 $2" = "api graphql" ]; then
    case "$*" in
        *closingIssuesReferences*)
            echo '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
            ;;
        *WatchThreadComments*)
            [ -z "${WATCH_GRAPHQL_LOG:-}" ] || printf '%s\n' "$*" >> "$WATCH_GRAPHQL_LOG"
            watch_reply_connection_count="$(
                printf '%s\n' "$*" |
                    grep -F -c 'comments(first: 100, after: $endCursor)' || true
            )"
            [ "$watch_reply_connection_count" -eq 1 ] || exit 47
            watch_reply_resolved=false
            watch_mutate_reply_ids=false
            [ "${WATCH_INCONSISTENT_THREAD_STATE:-false}" != true ] || \
                watch_reply_resolved=true
            [ "${WATCH_INCONSISTENT_THREAD_COMMENTS:-false}" != true ] || \
                watch_mutate_reply_ids=true
            if [ "${WATCH_THREAD_COMMENT_ERROR:-false}" = true ]; then
                echo '{"errors":[{"message":"reply page failed"}],"data":{"node":null}}'
            elif [ "${WATCH_INCOMPLETE_THREAD_COMMENTS:-false}" = true ]; then
                jq -nc --argjson resolved "$watch_reply_resolved" \
                    '[range(1; 101) | {id:("INLINE_" + tostring)}] as $comments
                    | {data:{node:{id:"THREAD_1",isResolved:$resolved,comments:{
                        pageInfo:{hasNextPage:false,endCursor:null},
                        totalCount:101,nodes:$comments}}}}'
            else
                jq -nc --argjson resolved "$watch_reply_resolved" \
                    --argjson mutate_ids "$watch_mutate_reply_ids" '
                    [range(1; 101) | {id:(if . == 1 and $mutate_ids then
                        "INLINE_CHANGED" else ("INLINE_" + tostring) end)}] as $comments
                    | {data:{node:{id:"THREAD_1",isResolved:$resolved,comments:{
                        pageInfo:{hasNextPage:true,endCursor:"reply-page-1"},
                        totalCount:101,nodes:$comments}}}}'
                jq -nc --argjson resolved "$watch_reply_resolved" \
                    '{data:{node:{id:"THREAD_1",isResolved:$resolved,comments:{
                    pageInfo:{hasNextPage:false,endCursor:null},
                    totalCount:101,nodes:[{id:"INLINE_101"}]}}}}'
            fi
            ;;
        *WatchReviewThreads*)
            [ -z "${WATCH_GRAPHQL_LOG:-}" ] || printf '%s\n' "$*" >> "$WATCH_GRAPHQL_LOG"
            if [ "${WATCH_INCOMPLETE_THREADS:-false}" = true ]; then
                echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":101,"pageInfo":{"hasNextPage":true,"endCursor":"x"},"nodes":[]}}}}}'
            elif [ "${WATCH_TWO_LEVEL:-false}" = true ] || \
                 [ "${WATCH_INCOMPLETE_THREAD_COMMENTS:-false}" = true ] || \
                 [ "${WATCH_THREAD_COMMENT_ERROR:-false}" = true ] || \
                 [ "${WATCH_INCONSISTENT_THREAD_STATE:-false}" = true ] || \
                 [ "${WATCH_INCONSISTENT_THREAD_COMMENTS:-false}" = true ]; then
                jq -nc '
                    [range(1; 101) | . as $thread_number | {
                        id:("THREAD_" + tostring),
                        isResolved:($thread_number != 1),
                        comments:(if $thread_number == 1 then {
                            totalCount:101,
                            nodes:[range(1; 101) | {id:("INLINE_" + tostring)}]
                        } else {totalCount:0,nodes:[]} end)
                    }] as $threads
                    | {data:{repository:{pullRequest:{reviewThreads:{
                        pageInfo:{hasNextPage:true,endCursor:"thread-page-1"},
                        totalCount:101,nodes:$threads}}}}}'
                jq -nc '{data:{repository:{pullRequest:{reviewThreads:{
                    pageInfo:{hasNextPage:false,endCursor:null},totalCount:101,
                    nodes:[{id:"THREAD_101",isResolved:true,
                        comments:{totalCount:0,nodes:[]}}]}}}}}'
            elif [ "$poll" -eq 0 ]; then
                echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"THREAD_OLD","isResolved":true,"isOutdated":false,"path":"a.js","line":1,"comments":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"INLINE_OLD","databaseId":10,"body":"old","author":{"login":"rev"},"createdAt":"2026-01-01T00:00:00Z","url":"https://github.com/o/r/pull/1#discussion_r10"}]}}]}}}}}'
            else
                echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
            fi
            ;;
        *)
            if [ "$poll" -eq 0 ]; then
                echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"THREAD_OLD","isResolved":true,"isOutdated":false,"path":"a.js","line":1,"comments":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"INLINE_OLD","databaseId":10,"body":"old","author":{"login":"rev"},"createdAt":"2026-01-01T00:00:00Z","url":"https://github.com/o/r/pull/1#discussion_r10"}]}}]}}}}}'
            else
                echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
            fi
            ;;
    esac
    exit 0
fi
if [ "$1" = "api" ] && [ "$2" = "--paginate" ]; then
    watch_projection=false
    case "$*" in *"--jq"*) watch_projection=true ;; esac
    if [ "$watch_projection" = true ] && [ -n "${WATCH_PROJECTION_LOG:-}" ]; then
        printf '%s\n' "$*" >> "$WATCH_PROJECTION_LOG"
        [ -z "${WATCH_LARGE_BODY_FILE:-}" ] || \
            wc -c < "$WATCH_LARGE_BODY_FILE" >> "$WATCH_PROJECTION_LOG"
    fi
    case "$3" in
        *issues/*/comments*)
            if [ "$watch_projection" = true ]; then
                if [ -n "${WATCH_LARGE_ID_COUNT:-}" ]; then
                    jq -nr --argjson count "$WATCH_LARGE_ID_COUNT" \
                        'range(1; $count + 1)'
                else
                    jq -nr 'range(1; 101)'
                fi
            else
                jq -nc '[range(1; 101) | {
                    id: ., body:"common", user:{login:"u"},
                    created_at:"2026-01-01T00:00:00Z",
                    updated_at:"2026-01-01T00:00:00Z",
                    html_url:("https://github.com/o/r/pull/1#issuecomment-" + tostring)
                }]'
            fi
            if [ "${WATCH_INCOMPLETE_BASE:-}" = "issue-comments" ] || \
               { [ "${WATCH_TRANSIENT_BASE_FAILURE:-false}" = true ] && \
                 [ "$poll" -eq 1 ]; } || \
               { [ "${WATCH_PERSISTENT_BASE_FAILURE:-false}" = true ] && \
                 [ "$poll" -gt 0 ]; }; then
                exit 41
            fi
            if [ "$poll" -eq 0 ]; then
                if [ "$watch_projection" = true ]; then
                    printf '101\n102\n'
                else
                    echo '[{"id":101,"body":"old","user":{"login":"u"},"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","html_url":"https://github.com/o/r/pull/1#issuecomment-101"},{"id":102,"body":"keep","user":{"login":"u"},"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","html_url":"https://github.com/o/r/pull/1#issuecomment-102"}]'
                fi
            else
                if [ "$watch_projection" = true ]; then
                    printf '103\n102\n104\n'
                else
                    echo '[{"id":103,"body":"new","user":{"login":"u"},"created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","html_url":"https://github.com/o/r/pull/1#issuecomment-103"},{"id":102,"body":"keep","user":{"login":"u"},"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","html_url":"https://github.com/o/r/pull/1#issuecomment-102"},{"id":104,"body":"added","user":{"login":"u"},"created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","html_url":"https://github.com/o/r/pull/1#issuecomment-104"}]'
                fi
            fi
            ;;
        *pulls/*/reviews*)
            if [ "$watch_projection" = true ]; then
                if [ -n "${WATCH_LARGE_ID_COUNT:-}" ]; then
                    jq -nr --argjson count "$WATCH_LARGE_ID_COUNT" \
                        'range(1001; 1001 + $count)'
                else
                    jq -nr 'range(1001; 1101)'
                fi
            else
                jq -nc '[range(1001; 1101) | {
                    id: ., body:"common", user:{login:"u"}, state:"COMMENTED",
                    submitted_at:"2026-01-01T00:00:00Z", commit_id:"abc123",
                    html_url:("https://github.com/o/r/pull/1#pullrequestreview-" + tostring)}]'
            fi
            if [ "${WATCH_INCOMPLETE_BASE:-}" = "reviews" ]; then
                exit 42
            fi
            if [ "$poll" -eq 0 ]; then
                if [ "$watch_projection" = true ]; then
                    echo '1101'
                else
                    echo '[{"id":1101,"body":"old","user":{"login":"u"},"state":"COMMENTED","submitted_at":"2026-01-01T00:00:00Z","commit_id":"abc123","html_url":"https://github.com/o/r/pull/1#pullrequestreview-1101"}]'
                fi
            else
                if [ "$watch_projection" = true ]; then
                    echo '1102'
                else
                    echo '[{"id":1102,"body":"new","user":{"login":"u"},"state":"COMMENTED","submitted_at":"2026-01-02T00:00:00Z","commit_id":"abc123","html_url":"https://github.com/o/r/pull/1#pullrequestreview-1102"}]'
                fi
            fi
            ;;
        *) echo '[]' ;;
    esac
    exit 0
fi
if [ "$1" = "api" ]; then echo '[]'; exit 0; fi
exit 0
STUB
chmod +x "$WATCH_STUB_DIR/gh"

cat > "$WATCH_STUB_DIR/claude" << 'STUB'
#!/bin/bash
attempt=$(cat "$WATCH_CLAUDE_ATTEMPT_FILE" 2>/dev/null || echo 0)
attempt=$((attempt + 1))
printf '%s\n' "$attempt" > "$WATCH_CLAUDE_ATTEMPT_FILE"
printf 'invoked\n' >> "$WATCH_CLAUDE_LOG"
cat > /dev/null
if [ "$attempt" -eq 1 ]; then
    echo '{"is_error":false,"result":"no structured output"}'
    exit 0
fi
jq -nc '
  ["logic_error","boundary_condition","concurrency","error_handling","resource_lifecycle","security","secrets_exposure","data_integrity","api_contract","performance","test_gap","observability","maintainability","documentation","build_ci","dependency_risk"] as $categories
  | {structured_output:{issue_categories:[],
      category_coverage:[$categories[] | {category:., verdict:"reviewed_none_found", note:"fixture"}],
      disputed_comments:[],systemic_issues:[],adjacent_problems:[],task_list:[],
      process_improvements:[],pr_template_suggestions:[]}}'
STUB
chmod +x "$WATCH_STUB_DIR/claude"

WATCH_OUT_FILE="$WATCH_CASE/watch.out"
set +e
(
    cd "$WATCH_WORK_DIR" || exit 1
    env WATCH_POLL_FILE="$WATCH_POLL_FILE" \
        WATCH_SLEEP_COUNT_FILE="$WATCH_SLEEP_COUNT_FILE" \
        WATCH_SLEEP_LIMIT=4 WATCH_TRANSIENT_BASE_FAILURE=true \
        WATCH_CLAUDE_ATTEMPT_FILE="$WATCH_CLAUDE_ATTEMPT_FILE" \
        WATCH_CLAUDE_LOG="$WATCH_CLAUDE_LOG" \
        GH_PR_ENRICH_HEARTBEAT_SECONDS=97 PATH="$WATCH_STUB_DIR:$PATH" \
        "$GH_PR_ENRICH" watch 1 --interval 1 --enrich
) > "$WATCH_OUT_FILE" 2>&1
set -e
WATCH_OUT=$(cat "$WATCH_OUT_FILE")
assert_contains "$WATCH_OUT" "New issue comments: +2" \
    "watch detects unseen IDs during same-component replacement"
assert_contains "$WATCH_OUT" "New review summaries: +1" \
    "watch detects a changed review ID from the second paginated page"
assert_not_contains "$WATCH_OUT" "Comment/review count change:" \
    "component offset is detected even when the aggregate count is unchanged"
assert_contains "$WATCH_OUT" "API request failed (attempt 1/3)" \
    "a transient incomplete base snapshot is retried under set -e"
assert_contains "$WATCH_OUT" "retaining the prior watch state for retry" \
    "watch retains its baseline when enrichment publishes no fresh selection"
assert_contains "$WATCH_OUT" "Analysis updated:" \
    "watch accepts the retry only after a fresh selected artifact is published"
assert_eq "2" "$(wc -l < "$WATCH_CLAUDE_LOG" | tr -d ' ')" \
    "failed enrichment retries once and a successful baseline does not rerun"
assert_eq "1" "$(grep -c 'Analysis updated:' "$WATCH_OUT_FILE")" \
    "a pre-existing analysis.md cannot masquerade as fresh output"
assert_jq "$WATCH_WORK_DIR/.reports/pr-reviews/pr-1/analysis.json" \
    '._metadata.repository == "o/r" and ._metadata.pr_number == 1' \
    "watch success is bound to a current selected artifact for the watched PR"

WATCH_LARGE_BODY_FILE="$WATCH_CASE/large-comment-body.txt"
WATCH_PROJECTION_LOG="$WATCH_CASE/projection.log"
LC_ALL=C awk 'BEGIN { for (i = 0; i < 1100000; i++) printf "x" }' \
    > "$WATCH_LARGE_BODY_FILE"
printf '0\n' > "$WATCH_POLL_FILE"
printf '0\n' > "$WATCH_SLEEP_COUNT_FILE"
: > "$WATCH_PROJECTION_LOG"
set +e
LARGE_BODY_WATCH_OUT=$(
    cd "$WATCH_WORK_DIR" && \
    env WATCH_LARGE_BODY_FILE="$WATCH_LARGE_BODY_FILE" \
        WATCH_PROJECTION_LOG="$WATCH_PROJECTION_LOG" \
        WATCH_POLL_FILE="$WATCH_POLL_FILE" \
        WATCH_SLEEP_COUNT_FILE="$WATCH_SLEEP_COUNT_FILE" WATCH_SLEEP_LIMIT=0 \
        PATH="$WATCH_STUB_DIR:$PATH" \
        "$GH_PR_ENRICH" watch 1 --interval 1 2>&1
)
set -e
assert_contains "$LARGE_BODY_WATCH_OUT" \
    "Initial state: 204 comments/reviews" \
    "watch initializes after API-side projection of bodies larger than macOS ARG_MAX"
assert_contains "$(cat "$WATCH_PROJECTION_LOG")" "--jq" \
    "paginated base comment and review fetches project IDs before shell capture"
assert_contains "$(cat "$WATCH_PROJECTION_LOG")" "1100000" \
    "the large-body regression exercises a payload beyond macOS ARG_MAX"

# The watch snapshot paginates the two GraphQL levels independently. The top
# query follows reviewThreads across 101 nodes without exposing a nested
# pageInfo to gh, then a comments-only query follows 101 replies for the one
# overflow thread.
WATCH_GRAPHQL_LOG="$WATCH_CASE/graphql-pagination.log"
printf '0\n' > "$WATCH_POLL_FILE"
printf '0\n' > "$WATCH_SLEEP_COUNT_FILE"
: > "$WATCH_GRAPHQL_LOG"
set +e
TWO_LEVEL_WATCH_OUT=$(
    cd "$WATCH_WORK_DIR" && \
    env WATCH_TWO_LEVEL=true WATCH_GRAPHQL_LOG="$WATCH_GRAPHQL_LOG" \
        WATCH_POLL_FILE="$WATCH_POLL_FILE" \
        WATCH_SLEEP_COUNT_FILE="$WATCH_SLEEP_COUNT_FILE" WATCH_SLEEP_LIMIT=0 \
        PATH="$WATCH_STUB_DIR:$PATH" \
        "$GH_PR_ENRICH" watch 1 --interval 1 2>&1
)
set -e
assert_contains "$TWO_LEVEL_WATCH_OUT" \
    "Initial state: 304 comments/reviews, 1 unresolved threads" \
    "watch captures 101 review threads and 101 replies without truncation"
assert_eq "1" "$(grep -c 'WatchReviewThreads' "$WATCH_GRAPHQL_LOG")" \
    "watch uses one independently paginated top-level thread query"
assert_eq "1" "$(grep -c 'WatchThreadComments' "$WATCH_GRAPHQL_LOG")" \
    "watch separately paginates the overflow thread's replies"
assert_contains "$(cat "$WATCH_GRAPHQL_LOG")" \
    'comments(first: 100) { totalCount nodes { id } }' \
    "top-level pagination omits nested comments pageInfo"
assert_contains "$(cat "$WATCH_GRAPHQL_LOG")" \
    'comments(first: 100, after: $endCursor)' \
    "overflow pagination advances the comments connection"

for reply_failure in incomplete error state-change comment-change; do
    printf '0\n' > "$WATCH_POLL_FILE"
    printf '0\n' > "$WATCH_SLEEP_COUNT_FILE"
    set +e
    if [ "$reply_failure" = incomplete ]; then
        REPLY_FAILURE_OUT=$(
            cd "$WATCH_WORK_DIR" && \
            env WATCH_INCOMPLETE_THREAD_COMMENTS=true \
                WATCH_POLL_FILE="$WATCH_POLL_FILE" \
                WATCH_SLEEP_COUNT_FILE="$WATCH_SLEEP_COUNT_FILE" \
                PATH="$WATCH_STUB_DIR:$PATH" \
                "$GH_PR_ENRICH" watch 1 --interval 1 2>&1
        )
    elif [ "$reply_failure" = error ]; then
        REPLY_FAILURE_OUT=$(
            cd "$WATCH_WORK_DIR" && \
            env WATCH_THREAD_COMMENT_ERROR=true \
                WATCH_POLL_FILE="$WATCH_POLL_FILE" \
                WATCH_SLEEP_COUNT_FILE="$WATCH_SLEEP_COUNT_FILE" \
                PATH="$WATCH_STUB_DIR:$PATH" \
                "$GH_PR_ENRICH" watch 1 --interval 1 2>&1
        )
    elif [ "$reply_failure" = state-change ]; then
        REPLY_FAILURE_OUT=$(
            cd "$WATCH_WORK_DIR" && \
            env WATCH_INCONSISTENT_THREAD_STATE=true \
                WATCH_POLL_FILE="$WATCH_POLL_FILE" \
                WATCH_SLEEP_COUNT_FILE="$WATCH_SLEEP_COUNT_FILE" \
                PATH="$WATCH_STUB_DIR:$PATH" \
                "$GH_PR_ENRICH" watch 1 --interval 1 2>&1
        )
    else
        REPLY_FAILURE_OUT=$(
            cd "$WATCH_WORK_DIR" && \
            env WATCH_INCONSISTENT_THREAD_COMMENTS=true \
                WATCH_POLL_FILE="$WATCH_POLL_FILE" \
                WATCH_SLEEP_COUNT_FILE="$WATCH_SLEEP_COUNT_FILE" \
                PATH="$WATCH_STUB_DIR:$PATH" \
                "$GH_PR_ENRICH" watch 1 --interval 1 2>&1
        )
    fi
    REPLY_FAILURE_RC=$?
    set -e
    assert_true "$([ "$REPLY_FAILURE_RC" -ne 0 ] && echo 0 || echo 1)" \
        "watch fails closed on $reply_failure overflow-reply pagination"
    assert_contains "$REPLY_FAILURE_OUT" \
        "Could not fetch the initial PR comment state" \
        "$reply_failure overflow replies cannot establish a watch baseline"
done

printf '0\n' > "$WATCH_POLL_FILE"
printf '0\n' > "$WATCH_SLEEP_COUNT_FILE"
set +e
LARGE_ID_WATCH_OUT=$(
    cd "$WATCH_WORK_DIR" && \
    env WATCH_LARGE_ID_COUNT=70000 WATCH_POLL_FILE="$WATCH_POLL_FILE" \
        WATCH_SLEEP_COUNT_FILE="$WATCH_SLEEP_COUNT_FILE" WATCH_SLEEP_LIMIT=1 \
        PATH="$WATCH_STUB_DIR:$PATH" \
        "$GH_PR_ENRICH" watch 1 --interval 1 2>&1
)
set -e
assert_contains "$LARGE_ID_WATCH_OUT" \
    "Initial state: 140001 comments/reviews" \
    "watch initializes with complete ID arrays beyond macOS ARG_MAX"
assert_contains "$LARGE_ID_WATCH_OUT" "Changes detected!" \
    "watch computes a large-state delta over stdin instead of argv"

for incomplete_component in issue-comments reviews; do
    printf '0\n' > "$WATCH_POLL_FILE"
    printf '0\n' > "$WATCH_SLEEP_COUNT_FILE"
    set +e
    INCOMPLETE_BASE_OUT=$(
        cd "$WATCH_WORK_DIR" && \
        env WATCH_INCOMPLETE_BASE="$incomplete_component" \
            WATCH_POLL_FILE="$WATCH_POLL_FILE" \
            WATCH_SLEEP_COUNT_FILE="$WATCH_SLEEP_COUNT_FILE" \
            PATH="$WATCH_STUB_DIR:$PATH" \
            "$GH_PR_ENRICH" watch 1 --interval 1 2>&1
    )
    INCOMPLETE_BASE_RC=$?
    set -e
    assert_true "$([ "$INCOMPLETE_BASE_RC" -ne 0 ] && echo 0 || echo 1)" \
        "watch fails closed on incomplete paginated $incomplete_component"
    assert_contains "$INCOMPLETE_BASE_OUT" \
        "Could not fetch the initial PR comment state" \
        "incomplete paginated $incomplete_component cannot establish a baseline"
done

printf '0\n' > "$WATCH_POLL_FILE"
printf '0\n' > "$WATCH_SLEEP_COUNT_FILE"
set +e
PERSISTENT_FAILURE_OUT=$(
    cd "$WATCH_WORK_DIR" && \
    env WATCH_PERSISTENT_BASE_FAILURE=true WATCH_POLL_FILE="$WATCH_POLL_FILE" \
        WATCH_SLEEP_COUNT_FILE="$WATCH_SLEEP_COUNT_FILE" \
        PATH="$WATCH_STUB_DIR:$PATH" \
        "$GH_PR_ENRICH" watch 1 --interval 1 2>&1
)
PERSISTENT_FAILURE_RC=$?
set -e
assert_true "$([ "$PERSISTENT_FAILURE_RC" -ne 0 ] && echo 0 || echo 1)" \
    "persistent watch snapshot failures exit nonzero"
assert_contains "$PERSISTENT_FAILURE_OUT" "API request failed (attempt 1/3)" \
    "the first persistent failure is reported instead of exiting via set -e"
assert_contains "$PERSISTENT_FAILURE_OUT" "API request failed (attempt 3/3)" \
    "watch retries snapshot failures through the configured maximum"
assert_contains "$PERSISTENT_FAILURE_OUT" "Too many consecutive failures" \
    "watch exits only after the configured consecutive-failure limit"

printf '0\n' > "$WATCH_POLL_FILE"
printf '0\n' > "$WATCH_SLEEP_COUNT_FILE"
set +e
INCOMPLETE_WATCH_OUT=$(
    cd "$WATCH_WORK_DIR" && \
    env WATCH_INCOMPLETE_THREADS=true WATCH_POLL_FILE="$WATCH_POLL_FILE" \
        WATCH_SLEEP_COUNT_FILE="$WATCH_SLEEP_COUNT_FILE" \
        PATH="$WATCH_STUB_DIR:$PATH" \
        "$GH_PR_ENRICH" watch 1 --interval 1 2>&1
)
INCOMPLETE_WATCH_RC=$?
set -e
assert_true "$([ "$INCOMPLETE_WATCH_RC" -ne 0 ] && echo 0 || echo 1)" \
    "watch fails closed when the review-thread ID snapshot is incomplete"
assert_contains "$INCOMPLETE_WATCH_OUT" "Could not fetch the initial PR comment state" \
    "watch reports an incomplete stable-ID baseline instead of silently truncating it"

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
