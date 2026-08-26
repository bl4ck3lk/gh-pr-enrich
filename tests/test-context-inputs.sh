#!/bin/bash
# Tests for what the analyzer is actually shown.
#
# Covers:
#   - review threads are paginated (a 101st thread must not vanish silently)
#   - outdated threads are labelled, not dropped
#   - superseded bot comments are deduplicated
#   - commits, linked issues and failing checks reach the context
#   - everything truncated or omitted is recorded in a coverage block

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GH_PR_ENRICH="$PROJECT_DIR/gh-pr-enrich"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output/context-inputs"
STUB_DIR="$TEST_OUTPUT_DIR/stubs"

# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

cleanup() { rm -rf "$TEST_OUTPUT_DIR"; }
trap cleanup EXIT
cleanup
mkdir -p "$TEST_OUTPUT_DIR" "$STUB_DIR"

suite_start "gh pr-enrich context inputs suite"

# ---------------------------------------------------------------------------
# Thread pagination: a stub gh returns two pages of review threads.
# ---------------------------------------------------------------------------
cat > "$STUB_DIR/gh" << 'STUB'
#!/bin/bash
# gh stub that behaves like the real one: it only walks pages when asked to.
# Without --paginate it returns the first page alone, so dropping pagination
# from fetch_review_threads makes the test fail instead of passing quietly.
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    printf '%s\n' "$@" > "${GH_STUB_ARG_LOG:-/dev/null}"
    paginate=false
    query=""
    for arg in "$@"; do
        [ "$arg" = "--paginate" ] && paginate=true
        case "$arg" in query=*) query="$arg" ;; esac
    done
    # The real `gh api graphql --paginate` requires the query to declare
    # pageInfo and accept an $endCursor variable; without them it cannot page.
    case "$query" in
        *pageInfo*endCursor*|*endCursor*pageInfo*) ;;
        *) paginate=false ;;
    esac
    cat << 'PAGE1'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":2,"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[
  {"id":"PRRT_page1","isResolved":false,"isOutdated":false,"path":"src/a.js","line":10,
   "comments":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"c1","databaseId":1,"body":"first page thread","author":{"login":"rev1"},"createdAt":"2026-01-01T00:00:00Z","url":"u1"}]}}
]}}}}}
PAGE1
    if [ "$paginate" = true ]; then
        cat << 'PAGE2'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":2,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRRT_page2","isResolved":false,"isOutdated":true,"path":"src/b.js","line":20,
   "comments":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"c2","databaseId":2,"body":"second page thread","author":{"login":"rev2"},"createdAt":"2026-01-02T00:00:00Z","url":"u2"}]}}
]}}}}}
PAGE2
    fi
    exit 0
fi
exit 1
STUB
chmod +x "$STUB_DIR/gh"

THREADS="$TEST_OUTPUT_DIR/comment-threads.json"
GH_ARGS_LOG="$TEST_OUTPUT_DIR/gh-args.txt"
env GH_STUB_ARG_LOG="$GH_ARGS_LOG" PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call fetch_review_threads owner repo 1 "$THREADS" >/dev/null 2>&1 || true

GH_ARGS=$(cat "$GH_ARGS_LOG" 2>/dev/null || echo "")
assert_contains "$GH_ARGS" "--paginate" "the thread fetch asks gh to follow pages"
assert_contains "$GH_ARGS" "pageInfo" "the query declares pageInfo so gh can page"
assert_contains "$GH_ARGS" "endCursor" "the query accepts an endCursor variable"

assert_jq_eq "$THREADS" '[.data.repository.pullRequest.reviewThreads.nodes[]] | length' "2" \
    "review threads from both pages are merged (pagination works)"
assert_jq "$THREADS" '[.data.repository.pullRequest.reviewThreads.nodes[].id] | index("PRRT_page2") != null' \
    "thread from the second page is not dropped"

# `gh pr view --json files,commits` caps both connections at 100. A summary
# that reaches either boundary must be completed from explicit paginated
# GraphQL connections before it can feed SAST or analyzer intent.
PR_CONNECTION_STUB_DIR="$TEST_OUTPUT_DIR/pr-connection-stubs"
PR_CONNECTION_ARGS="$TEST_OUTPUT_DIR/pr-connection-args.log"
PR_CONNECTION_SUMMARY="$TEST_OUTPUT_DIR/pr-connection-summary.json"
mkdir -p "$PR_CONNECTION_STUB_DIR"
cat > "$PR_CONNECTION_STUB_DIR/gh" << 'STUB'
#!/bin/bash
printf '%s\n' "$@" >> "$PR_CONNECTION_ARGS"
query=""
paginate=false
for arg in "$@"; do
    [ "$arg" != --paginate ] || paginate=true
    case "$arg" in query=*) query="$arg" ;; esac
done
pageable=false
if [ "$paginate" = true ]; then
    has_page_info=false
    has_cursor=false
    applies_cursor=false
    case "$query" in *pageInfo*) has_page_info=true ;; esac
    case "$query" in *'$endCursor'*) has_cursor=true ;; esac
    case "$query" in *'after: $endCursor'*) applies_cursor=true ;; esac
    if [ "$has_page_info" = true ] && [ "$has_cursor" = true ] && \
       [ "$applies_cursor" = true ]; then
        pageable=true
    fi
fi
case "$query" in
    *'files(first:'*)
        if [ "${PR_CONNECTION_MODE:-complete}" = partial-files ]; then
            jq -cn '{data:{repository:{pullRequest:{headRefOid:"head-1",baseRefOid:"base-1",files:{totalCount:101,pageInfo:{hasNextPage:false,endCursor:null},nodes:[range(0;100)|{path:("src/file-"+(tostring)+".js"),additions:1,deletions:0}]}}}}}'
            exit 0
        fi
        jq -cn '{data:{repository:{pullRequest:{headRefOid:"head-1",baseRefOid:"base-1",files:{totalCount:101,pageInfo:{hasNextPage:true,endCursor:"FILES-100"},nodes:[range(0;100)|{path:("src/file-"+(tostring)+".js"),additions:1,deletions:0}]}}}}}'
        if [ "$pageable" = true ]; then
            if [ "${PR_CONNECTION_MODE:-complete}" = head-drift ]; then
                jq -cn '{data:{repository:{pullRequest:{headRefOid:"head-2",baseRefOid:"base-1",files:{totalCount:101,pageInfo:{hasNextPage:false,endCursor:null},nodes:[{path:"src/file-100.js",additions:2,deletions:1}]}}}}}'
            else
                jq -cn '{data:{repository:{pullRequest:{headRefOid:"head-1",baseRefOid:"base-1",files:{totalCount:101,pageInfo:{hasNextPage:false,endCursor:null},nodes:[{path:"src/file-100.js",additions:2,deletions:1}]}}}}}'
            fi
        fi
        ;;
    *'commits(first:'*)
        if [ "${PR_CONNECTION_MODE:-complete}" = partial-commits ]; then
            jq -cn '{data:{repository:{pullRequest:{headRefOid:"head-1",baseRefOid:"base-1",commits:{totalCount:101,pageInfo:{hasNextPage:false,endCursor:null},nodes:[range(0;100)|{commit:{oid:("oid-"+(tostring)),messageHeadline:("commit "+(tostring)),messageBody:"body"}}]}}}}}'
            exit 0
        fi
        jq -cn '{data:{repository:{pullRequest:{headRefOid:"head-1",baseRefOid:"base-1",commits:{totalCount:101,pageInfo:{hasNextPage:true,endCursor:"COMMITS-100"},nodes:[range(0;100)|{commit:{oid:("oid-"+(tostring)),messageHeadline:("commit "+(tostring)),messageBody:"body"}}]}}}}}'
        if [ "$pageable" = true ]; then
            jq -cn '{data:{repository:{pullRequest:{headRefOid:"head-1",baseRefOid:"base-1",commits:{totalCount:101,pageInfo:{hasNextPage:false,endCursor:null},nodes:[{commit:{oid:"oid-100",messageHeadline:"commit 100",messageBody:"last body"}}]}}}}}'
        fi
        ;;
    *) exit 1 ;;
esac
STUB
chmod +x "$PR_CONNECTION_STUB_DIR/gh"
jq -n '{
    headRefOid: "head-1",
    baseRefOid: "base-1",
    changedFiles: 101,
    files: [range(0;100) | {path:("src/file-"+(tostring)+".js"), additions:1, deletions:0}],
    commits: [range(0;100) | {oid:("oid-"+(tostring)), messageHeadline:("commit "+(tostring)), messageBody:"body"}]
}' > "$PR_CONNECTION_SUMMARY"
env PR_CONNECTION_ARGS="$PR_CONNECTION_ARGS" PATH="$PR_CONNECTION_STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call complete_pr_summary_connections \
        owner/owner 1 "$PR_CONNECTION_SUMMARY" >/dev/null 2>&1
assert_jq "$PR_CONNECTION_SUMMARY" \
    '.changedFiles == 101 and (.files | length) == 101 and .files[-1].path == "src/file-100.js"' \
    "changed-file pagination completes the capped PR summary"
assert_jq "$PR_CONNECTION_SUMMARY" \
    '(.commits | length) == 101 and .commits[-1] == {oid:"oid-100",messageHeadline:"commit 100",messageBody:"last body"}' \
    "commit pagination completes the capped PR summary"
assert_true "$([ "$(grep -c -- '--paginate' "$PR_CONNECTION_ARGS")" -eq 2 ] && echo 0 || echo 1)" \
    "changed files and commits both use explicit pagination"

PR_CONNECTION_PARTIAL="$TEST_OUTPUT_DIR/pr-connection-partial.json"
jq '.files = .files[0:100] | .commits = []' "$PR_CONNECTION_SUMMARY" \
    > "$PR_CONNECTION_PARTIAL"
cp "$PR_CONNECTION_PARTIAL" "$PR_CONNECTION_PARTIAL.before"
rc=0
env PR_CONNECTION_MODE=partial-files PR_CONNECTION_ARGS="$PR_CONNECTION_ARGS" \
    PATH="$PR_CONNECTION_STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call complete_pr_summary_connections \
        owner/repo 1 "$PR_CONNECTION_PARTIAL" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a terminal changed-file page short of totalCount fails closed"
assert_true "$(cmp -s "$PR_CONNECTION_PARTIAL.before" "$PR_CONNECTION_PARTIAL"; echo $?)" \
    "failed connection completion leaves the original summary unchanged"

PR_CONNECTION_COMMIT_PARTIAL="$TEST_OUTPUT_DIR/pr-connection-commit-partial.json"
jq '.commits = .commits[0:100]' "$PR_CONNECTION_SUMMARY" \
    > "$PR_CONNECTION_COMMIT_PARTIAL"
cp "$PR_CONNECTION_COMMIT_PARTIAL" "$PR_CONNECTION_COMMIT_PARTIAL.before"
rc=0
env PR_CONNECTION_MODE=partial-commits PR_CONNECTION_ARGS="$PR_CONNECTION_ARGS" \
    PATH="$PR_CONNECTION_STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call complete_pr_summary_connections \
        owner/repo 1 "$PR_CONNECTION_COMMIT_PARTIAL" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a terminal commit page short of totalCount fails closed"
assert_true "$(cmp -s "$PR_CONNECTION_COMMIT_PARTIAL.before" \
    "$PR_CONNECTION_COMMIT_PARTIAL"; echo $?)" \
    "failed commit completion leaves the original summary unchanged"

PR_CONNECTION_DRIFT="$TEST_OUTPUT_DIR/pr-connection-head-drift.json"
jq '.files = .files[0:100] | .commits = []' "$PR_CONNECTION_SUMMARY" \
    > "$PR_CONNECTION_DRIFT"
cp "$PR_CONNECTION_DRIFT" "$PR_CONNECTION_DRIFT.before"
rc=0
env PR_CONNECTION_MODE=head-drift PR_CONNECTION_ARGS="$PR_CONNECTION_ARGS" \
    PATH="$PR_CONNECTION_STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call complete_pr_summary_connections \
        owner/repo 1 "$PR_CONNECTION_DRIFT" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "changed-file pagination rejects a head change between pages"
assert_true "$(cmp -s "$PR_CONNECTION_DRIFT.before" "$PR_CONNECTION_DRIFT"; echo $?)" \
    "head drift during pagination leaves the original summary unchanged"

# One live discussion identity spans several API requests. Two consecutive
# complete snapshots must agree before the hosted state is considered stable.
STABILITY_STUB_DIR="$TEST_OUTPUT_DIR/discussion-stability"
STABILITY_COUNT="$TEST_OUTPUT_DIR/discussion-stability-count"
mkdir -p "$STABILITY_STUB_DIR"
cat > "$STABILITY_STUB_DIR/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "api graphql" ]; then
    echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}'
    exit 0
fi
if [ "$1" = "api" ]; then
    case "$*" in
        *repos/o/r/issues/1/comments*)
            count=$(cat "$STABILITY_COUNT" 2>/dev/null || echo 0)
            count=$((count + 1))
            printf '%s\n' "$count" > "$STABILITY_COUNT"
            printf '[{"id":%s,"body":"state-%s","user":{"login":"u"},"created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z","html_url":"https://github.com/o/r/pull/1#issuecomment-%s"}]\n' \
                "$count" "$count" "$count"
            ;;
        *) echo '[]' ;;
    esac
    exit 0
fi
exit 1
STUB
chmod +x "$STABILITY_STUB_DIR/gh"
rc=0
env STABILITY_COUNT="$STABILITY_COUNT" PATH="$STABILITY_STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" --test-call fetch_live_analysis_discussion_fingerprint \
        o/r 1 >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a discussion mutation between composite snapshots fails revalidation"
assert_eq "2" "$(cat "$STABILITY_COUNT")" \
    "discussion revalidation requires two consecutive complete snapshots"

# A terminal page whose unique node count does not match totalCount is partial,
# even when GitHub reports hasNextPage=false.
COUNT_MISMATCH_STUB_DIR="$TEST_OUTPUT_DIR/thread-count-mismatch"
mkdir -p "$COUNT_MISMATCH_STUB_DIR"
cat > "$COUNT_MISMATCH_STUB_DIR/gh" << 'STUB'
#!/bin/bash
echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":2,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PRRT_only","isResolved":false,"isOutdated":false,"comments":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}]}}}}}'
STUB
chmod +x "$COUNT_MISMATCH_STUB_DIR/gh"
COUNT_MISMATCH_OUT="$TEST_OUTPUT_DIR/thread-count-mismatch.json"
rc=0
PATH="$COUNT_MISMATCH_STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call \
    fetch_review_threads owner repo 1 "$COUNT_MISMATCH_OUT" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "thread pagination rejects a terminal page short of totalCount"
assert_true "$([ ! -e "$COUNT_MISMATCH_OUT" ] && echo 0 || echo 1)" \
    "incomplete thread pagination publishes no partial thread document"

# ---------------------------------------------------------------------------
# A failing fetch must not leave an empty file behind
#
# `gh ... | jq ...` reports jq's exit status. When gh fails (missing scope,
# transient 5xx), jq reads nothing, exits 0, and the caller sees success with a
# zero-byte file — which then takes down the context build downstream.
# ---------------------------------------------------------------------------
FAIL_STUB_DIR="$TEST_OUTPUT_DIR/failing-gh"
mkdir -p "$FAIL_STUB_DIR"
cat > "$FAIL_STUB_DIR/gh" << 'STUB'
#!/bin/bash
echo "gh: HTTP 502 (Bad Gateway)" >&2
exit 1
STUB
chmod +x "$FAIL_STUB_DIR/gh"

LINKED_OUT="$TEST_OUTPUT_DIR/linked-from-failure.json"
PATH="$FAIL_STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call fetch_linked_issues owner repo 1 "$LINKED_OUT" >/dev/null 2>&1 || true

if [ -s "$LINKED_OUT" ]; then
    assert_jq "$LINKED_OUT" 'type == "array" and length == 0' \
        "a failed linked-issue fetch still writes a valid empty array"
else
    fail "a failed linked-issue fetch still writes a valid empty array" \
        "file is zero bytes, which breaks the context build"
fi

# The same applies to the thread fetch.
THREADS_OUT="$TEST_OUTPUT_DIR/threads-from-failure.json"
rc=0
PATH="$FAIL_STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call fetch_review_threads owner repo 1 "$THREADS_OUT" >/dev/null 2>&1 || rc=$?
assert_eq "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)" "a failed thread fetch reports failure to its caller"

# GraphQL can return HTTP 200 with an errors envelope or no response pages. Both
# must remain failed coverage rather than completed empty input.
ERROR_STUB_DIR="$TEST_OUTPUT_DIR/graphql-error-gh"
mkdir -p "$ERROR_STUB_DIR"
cat > "$ERROR_STUB_DIR/gh" << 'STUB'
#!/bin/bash
echo '{"errors":[{"message":"scope denied"}],"data":{"repository":null}}'
exit 0
STUB
chmod +x "$ERROR_STUB_DIR/gh"

GRAPHQL_ERROR_THREADS="$TEST_OUTPUT_DIR/threads-from-graphql-error.json"
rc=0
PATH="$ERROR_STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call fetch_review_threads \
    owner repo 1 "$GRAPHQL_ERROR_THREADS" >/dev/null 2>&1 || rc=$?
assert_eq "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)" \
    "an HTTP-200 GraphQL error fails the review-thread fetch"

GRAPHQL_ERROR_LINKED="$TEST_OUTPUT_DIR/linked-from-graphql-error.json"
rc=0
PATH="$ERROR_STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call fetch_linked_issues \
    owner repo 1 "$GRAPHQL_ERROR_LINKED" >/dev/null 2>&1 || rc=$?
assert_eq "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)" \
    "an HTTP-200 GraphQL error fails the linked-issue fetch"

# Linked issue intent is complete across the full GraphQL connection. A
# successful page one must not conceal issue 101 or publish an ambiguous cap.
LINKED_PAGES_STUB_DIR="$TEST_OUTPUT_DIR/linked-pages-gh"
mkdir -p "$LINKED_PAGES_STUB_DIR"
cat > "$LINKED_PAGES_STUB_DIR/gh" << 'STUB'
#!/bin/bash
printf '%s\n' "$*" > "$LINKED_ARGS_LOG"
jq -nc '{data:{repository:{pullRequest:{closingIssuesReferences:{
    totalCount:101,pageInfo:{hasNextPage:true,endCursor:"cursor-100"},
    nodes:[range(1;101) | {id:("ISSUE_" + tostring),number:.,title:("issue " + tostring),body:"body",url:("u" + tostring)}]
}}}}}'
jq -nc '{data:{repository:{pullRequest:{closingIssuesReferences:{
    totalCount:101,pageInfo:{hasNextPage:false,endCursor:null},
    nodes:[{id:"ISSUE_101",number:101,title:"issue 101",body:"body",url:"u101"}]
}}}}}'
STUB
chmod +x "$LINKED_PAGES_STUB_DIR/gh"
LINKED_PAGES_OUT="$TEST_OUTPUT_DIR/linked-pages.json"
LINKED_ARGS_LOG="$TEST_OUTPUT_DIR/linked-pages-args.txt"
env PATH="$LINKED_PAGES_STUB_DIR:$PATH" LINKED_ARGS_LOG="$LINKED_ARGS_LOG" \
    "$GH_PR_ENRICH" --test-call fetch_linked_issues \
    owner repo 1 "$LINKED_PAGES_OUT" >/dev/null 2>&1
LINKED_ARGS=$(cat "$LINKED_ARGS_LOG")
assert_contains "$LINKED_ARGS" "--paginate" \
    "the linked-issue fetch asks gh to follow every page"
assert_contains "$LINKED_ARGS" 'after: $endCursor' \
    "the linked-issue query binds the pagination cursor"
assert_contains "$LINKED_ARGS" "totalCount" \
    "the linked-issue query requests a completeness proof"
assert_contains "$LINKED_ARGS" "nameWithOwner visibility" \
    "the linked-issue query binds every issue to its source repository visibility"
assert_jq_eq "$LINKED_PAGES_OUT" 'length' "101" \
    "linked issues from every page are merged"
assert_jq "$LINKED_PAGES_OUT" 'any(.[]; .id == "ISSUE_101")' \
    "the linked issue after the first 100 is retained"
assert_jq "$LINKED_PAGES_OUT" \
    'all(.[]; .repository == {nameWithOwner:"",visibility:"UNKNOWN"})' \
    "missing source visibility is retained as unknown for a fail-closed provider gate"

# A transport that stops early or repeats an opaque node identity fails closed
# and retains the valid-empty failure artifact expected by context builders.
INCOMPLETE_LINKED_STUB_DIR="$TEST_OUTPUT_DIR/incomplete-linked-gh"
mkdir -p "$INCOMPLETE_LINKED_STUB_DIR"
cat > "$INCOMPLETE_LINKED_STUB_DIR/gh" << 'STUB'
#!/bin/bash
jq -nc '{data:{repository:{pullRequest:{closingIssuesReferences:{
    totalCount:2,pageInfo:{hasNextPage:false,endCursor:null},
    nodes:[{id:"ISSUE_1",number:1,title:"one",body:"body",url:"u1"}]
}}}}}'
STUB
chmod +x "$INCOMPLETE_LINKED_STUB_DIR/gh"
INCOMPLETE_LINKED_OUT="$TEST_OUTPUT_DIR/incomplete-linked.json"
rc=0
PATH="$INCOMPLETE_LINKED_STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call \
    fetch_linked_issues owner repo 1 "$INCOMPLETE_LINKED_OUT" \
    >/dev/null 2>&1 || rc=$?
assert_eq "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)" \
    "an incomplete linked-issue connection fails coverage"
assert_jq "$INCOMPLETE_LINKED_OUT" 'type == "array" and length == 0' \
    "an incomplete linked-issue connection publishes no partial intent"

DUPLICATE_LINKED_STUB_DIR="$TEST_OUTPUT_DIR/duplicate-linked-gh"
mkdir -p "$DUPLICATE_LINKED_STUB_DIR"
cat > "$DUPLICATE_LINKED_STUB_DIR/gh" << 'STUB'
#!/bin/bash
jq -nc '{data:{repository:{pullRequest:{closingIssuesReferences:{
    totalCount:2,pageInfo:{hasNextPage:true,endCursor:"cursor-1"},
    nodes:[{id:"ISSUE_1",number:1,title:"one",body:"body",url:"u1"}]
}}}}}'
jq -nc '{data:{repository:{pullRequest:{closingIssuesReferences:{
    totalCount:2,pageInfo:{hasNextPage:false,endCursor:null},
    nodes:[{id:"ISSUE_1",number:1,title:"one",body:"body",url:"u1"}]
}}}}}'
STUB
chmod +x "$DUPLICATE_LINKED_STUB_DIR/gh"
DUPLICATE_LINKED_OUT="$TEST_OUTPUT_DIR/duplicate-linked.json"
rc=0
PATH="$DUPLICATE_LINKED_STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call \
    fetch_linked_issues owner repo 1 "$DUPLICATE_LINKED_OUT" \
    >/dev/null 2>&1 || rc=$?
assert_eq "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)" \
    "duplicate linked-issue identities fail pagination validation"
assert_jq "$DUPLICATE_LINKED_OUT" 'type == "array" and length == 0' \
    "duplicate linked-issue pages publish no ambiguous intent"

EMPTY_SUCCESS_STUB_DIR="$TEST_OUTPUT_DIR/graphql-empty-gh"
mkdir -p "$EMPTY_SUCCESS_STUB_DIR"
cat > "$EMPTY_SUCCESS_STUB_DIR/gh" << 'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$EMPTY_SUCCESS_STUB_DIR/gh"
rc=0
PATH="$EMPTY_SUCCESS_STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call fetch_review_threads \
    owner repo 1 "$TEST_OUTPUT_DIR/threads-from-empty-success.json" >/dev/null 2>&1 || rc=$?
assert_eq "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)" \
    "a zero-page successful GraphQL call fails the review-thread fetch"

# ---------------------------------------------------------------------------
# Outdated threads are labelled and kept
# ---------------------------------------------------------------------------
UNRESOLVED="$TEST_OUTPUT_DIR/unresolved-threads.json"
"$GH_PR_ENRICH" --test-call extract_unresolved_threads "$THREADS" "$UNRESOLVED" >/dev/null 2>&1 || true

assert_jq_eq "$UNRESOLVED" 'length' "2" "both unresolved threads are extracted"
assert_jq "$UNRESOLVED" '[.[] | select(.thread_id == "PRRT_page2")][0].is_outdated == true' \
    "outdated thread is labelled is_outdated"
assert_jq "$UNRESOLVED" '[.[] | select(.thread_id == "PRRT_page1")][0].path == "src/a.js"' \
    "thread carries its file path"
assert_jq "$UNRESOLVED" '[.[] | select(.thread_id == "PRRT_page1")][0].line == 10' \
    "thread carries its line number"

# ---------------------------------------------------------------------------
# Bot comment deduplication
# ---------------------------------------------------------------------------
RAW_COMMENTS="$TEST_OUTPUT_DIR/issue-comments.json"
cat > "$RAW_COMMENTS" << 'EOF'
[
  {"id":1,"body":"## Coverage report\n\n72% of lines covered","user":"codecov[bot]",
   "created_at":"2026-01-01T10:00:00Z","type":"issue_comment","html_url":"h1"},
  {"id":2,"body":"## Coverage report\n\n81% of lines covered","user":"codecov[bot]",
   "created_at":"2026-01-02T10:00:00Z","type":"issue_comment","html_url":"h2"},
  {"id":3,"body":"## Coverage report\n\n84% of lines covered","user":"codecov[bot]",
   "created_at":"2026-01-03T10:00:00Z","type":"issue_comment","html_url":"h3"},
  {"id":4,"body":"## Security scan\n\n1 high finding","user":"codecov[bot]",
   "created_at":"2026-01-03T11:00:00Z","type":"issue_comment","html_url":"h4"},
  {"id":5,"body":"Looks good to me","user":"human-reviewer",
   "created_at":"2026-01-01T09:00:00Z","type":"issue_comment","html_url":"h5"},
  {"id":6,"body":"Looks good to me","user":"human-reviewer",
   "created_at":"2026-01-02T09:00:00Z","type":"issue_comment","html_url":"h6"}
]
EOF

DEDUPED="$TEST_OUTPUT_DIR/deduped.json"
"$GH_PR_ENRICH" --test-call dedupe_bot_comments "$RAW_COMMENTS" "$DEDUPED" >/dev/null 2>&1 || true

assert_jq_eq "$DEDUPED" '[.kept[] | select(.user == "codecov[bot]" and (.body | contains("Coverage report")))] | length' "1" \
    "superseded bot reposts collapse to one"
assert_jq_eq "$DEDUPED" '[.kept[] | select(.body | contains("84% of lines covered"))] | length' "1" \
    "the newest bot report is the one kept"
assert_jq_eq "$DEDUPED" '[.kept[] | select(.body | contains("72% of lines covered"))] | length' "0" \
    "older bot reports are dropped"
assert_jq_eq "$DEDUPED" '[.kept[] | select(.user == "codecov[bot]")] | length' "2" \
    "distinct bot report types are both kept"
assert_jq_eq "$DEDUPED" '[.kept[] | select(.user == "human-reviewer")] | length' "2" \
    "repeated human comments are never deduplicated"
assert_jq_eq "$DEDUPED" '.superseded | length' "2" "superseded comments are recorded"

# Distinct reports that share an opening line must survive. Bots commonly prefix
# every comment with the same marker or status heading, so a first-line-only
# signature silently discards unrelated findings.
SHARED_PREFIX="$TEST_OUTPUT_DIR/shared-prefix.json"
cat > "$SHARED_PREFIX" << 'EOF'
[
  {"id":1,"body":"### Job failed\n\nunit-tests: 3 assertions failed","user":"github-actions[bot]",
   "created_at":"2026-01-01T10:00:00Z","type":"issue_comment","html_url":"h1"},
  {"id":2,"body":"### Job failed\n\ne2e: login flow timed out","user":"github-actions[bot]",
   "created_at":"2026-01-01T11:00:00Z","type":"issue_comment","html_url":"h2"},
  {"id":3,"body":"<!-- auto-generated -->\n\nSQL injection risk in db.js","user":"coderabbitai[bot]",
   "created_at":"2026-01-01T12:00:00Z","type":"issue_comment","html_url":"h3"},
  {"id":4,"body":"<!-- auto-generated -->\n\nWalkthrough of the changes","user":"coderabbitai[bot]",
   "created_at":"2026-01-01T13:00:00Z","type":"issue_comment","html_url":"h4"}
]
EOF

SHARED_OUT="$TEST_OUTPUT_DIR/shared-prefix-deduped.json"
"$GH_PR_ENRICH" --test-call dedupe_bot_comments "$SHARED_PREFIX" "$SHARED_OUT" >/dev/null 2>&1 || true

assert_jq_eq "$SHARED_OUT" '.kept | length' "4" \
    "distinct bot reports sharing an opening line are all kept"
assert_jq_eq "$SHARED_OUT" '[.kept[] | select(.body | contains("SQL injection"))] | length' "1" \
    "a security finding is not discarded as a duplicate of a walkthrough"
assert_jq_eq "$SHARED_OUT" '[.kept[] | select(.body | contains("unit-tests"))] | length' "1" \
    "two different CI failures are not collapsed into one"

# Whatever is dropped must be auditable, not merely counted.
assert_jq "$DEDUPED" '[.superseded[] | select(.html_url != null)] | length == 2' \
    "superseded comments keep their URLs so a drop can be reviewed"

# ---------------------------------------------------------------------------
# Context inputs: commits, linked issues, failing checks, coverage
# ---------------------------------------------------------------------------
CTX_DIR="$TEST_OUTPUT_DIR/ctx"
mkdir -p "$CTX_DIR"
cp "$RAW_COMMENTS" "$CTX_DIR/issue-comments.json"
cp "$UNRESOLVED" "$CTX_DIR/unresolved-threads.json"

cat > "$CTX_DIR/pr-summary.json" << 'EOF'
{
  "number": 7,
  "title": "Add retry logic",
  "body": "Fixes #42",
  "author": {"login": "dev"},
  "files": [{"path": "src/retry.js"}],
  "commits": [
    {"oid": "abc123def456", "messageHeadline": "Add retry with backoff", "messageBody": "Caps at 5 attempts."},
    {"oid": "789beefcafe0", "messageHeadline": "Fix lint", "messageBody": ""}
  ]
}
EOF

cat > "$CTX_DIR/checks.json" << 'EOF'
[
  {"name": "unit-tests", "state": "FAILURE", "bucket": "fail", "link": "https://ci/1", "description": "3 tests failed"},
  {"name": "lint", "state": "SUCCESS", "bucket": "pass", "link": "https://ci/2", "description": ""}
]
EOF

cat > "$CTX_DIR/linked-issues.json" << 'EOF'
[{"number": 42, "title": "Requests fail on flaky network", "body": "Users see 500s when upstream is slow.", "url": "https://gh/42", "repository":{"nameWithOwner":"intent/issues","visibility":"PRIVATE"}}]
EOF

cat > "$CTX_DIR/review-comments.json" << 'EOF'
[{"id":11,"body":"Review summary body","user":"reviewer","state":"CHANGES_REQUESTED","submitted_at":"2026-01-03T00:00:00Z","html_url":"https://gh/review/11"}]
EOF
cat > "$CTX_DIR/inline-comments.json" << 'EOF'
[{"id":12,"body":"Inline feedback body","user":"reviewer","path":"src/retry.js","line":12,"created_at":"2026-01-03T00:00:00Z","html_url":"https://gh/comment/12"}]
EOF
for source in issue-comments review-comments inline-comments review-threads checks linked-issues; do
    jq -n '{requested:true,status:"completed",reason:""}' > "$CTX_DIR/$source-status.json"
done

cat > "$CTX_DIR/sast-findings.json" << 'EOF'
[{"check_id": "javascript.lang.security.audit.unsafe-exec", "path": "src/retry.js", "line": 12, "severity": "ERROR", "message": "Unsafe exec"}]
EOF

# A file diff long enough to be truncated
python3 - "$CTX_DIR/pr-diff.json" << 'PY'
import json, sys
big = "diff --git a/src/retry.js b/src/retry.js\n" + ("+ // padding line\n" * 700)
json.dump({"raw_diff": big, "file_diffs": [
    {"file": "src/retry.js", "content": big},
    {"file": "src/small.js", "content": "diff --git a/src/small.js b/src/small.js\n+ ok\n"}
]}, open(sys.argv[1], "w"))
PY

CTX="$CTX_DIR/claude-context.json"
"$GH_PR_ENRICH" --test-call build_claude_context "$CTX_DIR" true >/dev/null 2>&1 || true

assert_jq_eq "$CTX" '.pr.commits | length' "2" "commit messages reach the context"
assert_jq "$CTX" '.pr.commits[0].message | contains("Add retry with backoff")' "commit headline is included"
assert_jq_eq "$CTX" '.pr.linked_issues | length' "1" "linked issue reaches the context"
assert_jq "$CTX" '.pr.linked_issues[0].body | contains("upstream is slow")' "linked issue body is included"
assert_jq "$CTX" \
    '.pr.linked_issues[0].repository == {name_with_owner:"intent/issues",visibility:"PRIVATE"}' \
    "linked issue source visibility remains bound in the native analysis context"
assert_jq_eq "$CTX" '.failing_checks | length' "1" "only failing checks are included"
assert_jq "$CTX" '.failing_checks[0].name == "unit-tests"' "failing check is named"
assert_jq_eq "$CTX" '.sast_findings | length' "1" "sast findings reach the context when present"
assert_jq "$CTX" \
    '.coverage.sast.status == "completed" and
     .coverage.sast.reason == "status inferred from prebuilt SAST findings" and
     .coverage.sast.findings == 1' \
    "legacy two-argument context callers retain prebuilt SAST findings"

for malformed_mode in legacy current; do
    MALFORMED_SAST_DIR="$TEST_OUTPUT_DIR/malformed-sast-$malformed_mode"
    mkdir -p "$MALFORMED_SAST_DIR"
    cp "$CTX_DIR/pr-summary.json" "$MALFORMED_SAST_DIR/pr-summary.json"
    echo '[]' > "$MALFORMED_SAST_DIR/unresolved-threads.json"
    echo '[]' > "$MALFORMED_SAST_DIR/issue-comments.json"
    echo '{not valid JSON' > "$MALFORMED_SAST_DIR/sast-findings.json"
    if [ "$malformed_mode" = current ]; then
        jq -n '{requested:true,status:"completed",reason:"",
            workspace_source:"immutable_snapshot",
            workspace_fingerprint:"sha256:fixture"}' \
            > "$MALFORMED_SAST_DIR/sast-status.json"
        "$GH_PR_ENRICH" --test-call build_claude_context \
            "$MALFORMED_SAST_DIR" false true >/dev/null 2>&1
    else
        "$GH_PR_ENRICH" --test-call build_claude_context \
            "$MALFORMED_SAST_DIR" false >/dev/null 2>&1
    fi
    assert_jq "$MALFORMED_SAST_DIR/claude-context.json" \
        '.sast_findings == [] and .coverage.sast.status == "failed" and
         (.coverage.sast.reason | contains("not a valid JSON array")) and
         .coverage.sast.findings == 0' \
        "$malformed_mode malformed SAST is failed coverage, never inferred clean"
    assert_jq "$MALFORMED_SAST_DIR/sast-findings.json" '. == []' \
        "$malformed_mode malformed SAST uses an empty safe jq payload after failure"
done
assert_jq "$CTX" '.review_comments[0].body == "Review summary body"' \
    "top-level review summaries reach the analysis context"
assert_jq "$CTX" '.inline_comments[0].body == "Inline feedback body"' \
    "inline REST comments reach the analysis context"

# Thread context carries the outdated flag through to the analyzer
assert_jq "$CTX" '[.unresolved_threads[] | select(.thread_id == "PRRT_page2")][0].is_outdated == true' \
    "analyzer is told which threads are outdated"

# Bot dedup applied on the way into the context
assert_jq_eq "$CTX" '[.issue_comments[] | select(.body | contains("Coverage report"))] | length' "1" \
    "context contains one coverage report, not three"

# Coverage block
assert_jq "$CTX" '.coverage != null' "context records a coverage block"
assert_jq_eq "$CTX" '.coverage.issue_comments.total' "6" "coverage records total issue comments"
assert_jq_eq "$CTX" '.coverage.issue_comments.superseded_bot_duplicates' "2" \
    "coverage records how many bot duplicates were dropped"
assert_jq_eq "$CTX" '.coverage.unresolved_threads.outdated' "1" "coverage counts outdated threads"
assert_jq_eq "$CTX" '.coverage.diff.files_truncated | length' "1" "coverage names truncated diff files"
assert_jq "$CTX" '.coverage.diff.files_truncated | index("src/retry.js") != null' \
    "coverage names which file was truncated"
assert_jq_eq "$CTX" '.coverage.truncation_limit_chars' "5000" "coverage states the truncation limit"
assert_jq "$CTX" '.coverage.sources | to_entries | all(.value.status == "completed")' \
    "coverage records successful GitHub source fetches explicitly"
assert_jq "$CTX" \
    '.coverage.checks.fingerprint | type == "string" and length > 0' \
    "coverage binds a completed checks snapshot to the analysis context"

CHECKS_FINGERPRINT="$($GH_PR_ENRICH --test-call \
    analysis_checks_fingerprint_from_file "$CTX_DIR/checks.json")"
jq 'reverse' "$CTX_DIR/checks.json" > "$CTX_DIR/checks-reordered.json"
REORDERED_CHECKS_FINGERPRINT="$($GH_PR_ENRICH --test-call \
    analysis_checks_fingerprint_from_file "$CTX_DIR/checks-reordered.json")"
assert_eq "$CHECKS_FINGERPRINT" "$REORDERED_CHECKS_FINGERPRINT" \
    "checks fingerprint ignores response ordering"
jq '.[0].state = "SUCCESS" | .[0].bucket = "pass"' \
    "$CTX_DIR/checks.json" > "$CTX_DIR/checks-state-changed.json"
CHANGED_CHECKS_FINGERPRINT="$($GH_PR_ENRICH --test-call \
    analysis_checks_fingerprint_from_file "$CTX_DIR/checks-state-changed.json")"
assert_true "$([ "$CHECKS_FINGERPRINT" != "$CHANGED_CHECKS_FINGERPRINT" ] && echo 0 || echo 1)" \
    "a check result transition changes the checks fingerprint"
printf '[]\n' > "$CTX_DIR/checks-empty.json"
EMPTY_CHECKS_FINGERPRINT="$($GH_PR_ENRICH --test-call \
    analysis_checks_fingerprint_from_file "$CTX_DIR/checks-empty.json")"
assert_true "$([ -n "$EMPTY_CHECKS_FINGERPRINT" ] && echo 0 || echo 1)" \
    "an empty no-checks snapshot has a valid fingerprint"

LIVE_CHECKS_STUB_DIR="$TEST_OUTPUT_DIR/live-checks-stubs"
LIVE_CHECKS_COUNT="$TEST_OUTPUT_DIR/live-checks-count"
mkdir -p "$LIVE_CHECKS_STUB_DIR"
cat > "$LIVE_CHECKS_STUB_DIR/gh" << 'STUB'
#!/bin/bash
[ "$1 $2" = "pr checks" ] || exit 1
count=$(cat "$LIVE_CHECKS_COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$LIVE_CHECKS_COUNT"
failing='[{"name":"unit","state":"FAILURE","bucket":"fail","workflow":"tests","startedAt":"s","completedAt":"c","event":"pull_request","link":"u","description":"failed"}]'
case "$LIVE_CHECKS_MODE" in
    stable-failing) printf '%s\n' "$failing"; exit 1 ;;
    unstable)
        if [ "$count" -eq 1 ]; then printf '[]\n'; exit 0; fi
        printf '%s\n' "$failing"; exit 1
        ;;
    malformed) printf '{not-json\n'; exit 1 ;;
esac
exit 1
STUB
chmod +x "$LIVE_CHECKS_STUB_DIR/gh"
printf '0\n' > "$LIVE_CHECKS_COUNT"
rc=0
STABLE_FAILING_FINGERPRINT=$(env PATH="$LIVE_CHECKS_STUB_DIR:$PATH" \
    LIVE_CHECKS_MODE=stable-failing LIVE_CHECKS_COUNT="$LIVE_CHECKS_COUNT" \
    "$GH_PR_ENRICH" --test-call fetch_live_analysis_checks_fingerprint \
        o/r 1 2>/dev/null) || rc=$?
assert_true "$([ "$rc" -eq 0 ] && [ -n "$STABLE_FAILING_FINGERPRINT" ] && echo 0 || echo 1)" \
    "nonzero gh status with stable parseable failing checks remains valid evidence"
printf '0\n' > "$LIVE_CHECKS_COUNT"
rc=0
env PATH="$LIVE_CHECKS_STUB_DIR:$PATH" LIVE_CHECKS_MODE=unstable \
    LIVE_CHECKS_COUNT="$LIVE_CHECKS_COUNT" \
    "$GH_PR_ENRICH" --test-call fetch_live_analysis_checks_fingerprint \
        o/r 1 >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "two different consecutive check snapshots fail closed"
printf '0\n' > "$LIVE_CHECKS_COUNT"
rc=0
env PATH="$LIVE_CHECKS_STUB_DIR:$PATH" LIVE_CHECKS_MODE=malformed \
    LIVE_CHECKS_COUNT="$LIVE_CHECKS_COUNT" \
    "$GH_PR_ENRICH" --test-call fetch_live_analysis_checks_fingerprint \
        o/r 1 >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a malformed live checks response fails closed"

MALFORMED_CHECKS_DIR="$TEST_OUTPUT_DIR/malformed-completed-checks"
mkdir -p "$MALFORMED_CHECKS_DIR"
cp "$CTX_DIR/pr-summary.json" "$MALFORMED_CHECKS_DIR/pr-summary.json"
printf '[]\n' > "$MALFORMED_CHECKS_DIR/unresolved-threads.json"
printf '[]\n' > "$MALFORMED_CHECKS_DIR/issue-comments.json"
printf '{not valid JSON\n' > "$MALFORMED_CHECKS_DIR/checks.json"
jq -n '{requested:true,status:"completed",reason:""}' \
    > "$MALFORMED_CHECKS_DIR/checks-status.json"
rc=0
"$GH_PR_ENRICH" --test-call build_claude_context \
    "$MALFORMED_CHECKS_DIR" false >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a malformed checks document cannot satisfy completed checks coverage"

# A thread's replies are fetched with a per-thread cap. A thread that hits the
# cap has lost replies, and the coverage block is the only place that can say so.
CAP_DIR="$TEST_OUTPUT_DIR/capped"
mkdir -p "$CAP_DIR"
cp "$CTX_DIR/pr-summary.json" "$CAP_DIR/pr-summary.json"
echo '[]' > "$CAP_DIR/issue-comments.json"
python3 - "$CAP_DIR/unresolved-threads.json" << 'PY'
import json, sys
# One thread at the 20-comment fetch cap, one comfortably under it.
threads = [
    {"thread_id": "PRRT_full", "is_outdated": False, "path": "a.js", "line": 1,
     "comments": [{"author": "r", "body": "reply %d" % i, "url": "u%d" % i} for i in range(20)]},
    {"thread_id": "PRRT_small", "is_outdated": False, "path": "b.js", "line": 2,
     "comments": [{"author": "r", "body": "only reply", "url": "u"}]},
]
json.dump(threads, open(sys.argv[1], "w"))
PY

"$GH_PR_ENRICH" --test-call build_claude_context "$CAP_DIR" false >/dev/null 2>&1 || true
CAP_CTX="$CAP_DIR/claude-context.json"

assert_jq_eq "$CAP_CTX" '.coverage.unresolved_threads.comments_per_thread_limit' "20" \
    "coverage states the per-thread comment limit"
assert_jq_eq "$CAP_CTX" '.coverage.unresolved_threads.threads_at_comment_limit' "1" \
    "coverage counts threads whose replies may have been cut off"
assert_jq "$CAP_CTX" \
    '.coverage.unresolved_threads.incomplete_comment_threads == ["PRRT_full"]' \
    "coverage identifies the exact thread whose later replies were omitted"

# ---------------------------------------------------------------------------
# Truncation: the marker, the boundary, and the configured limit
# ---------------------------------------------------------------------------
assert_jq "$CTX" '[.code_changes.file_diffs[] | select(.diff | contains("(truncated)"))] | length == 1' \
    "an oversized file diff carries the truncation marker"
assert_jq "$CTX" '[.code_changes.file_diffs[] | select(.file == "src/small.js" and (.diff | contains("(truncated)")))] | length == 0' \
    "a small file diff is not marked truncated"

# A comment of exactly the limit must not be truncated; one byte more must be.
BOUNDARY_DIR="$TEST_OUTPUT_DIR/boundary"
mkdir -p "$BOUNDARY_DIR"
cp "$CTX_DIR/pr-summary.json" "$BOUNDARY_DIR/pr-summary.json"
python3 - "$BOUNDARY_DIR/unresolved-threads.json" << 'PY'
import json, sys
json.dump([{
    "thread_id": "PRRT_boundary", "is_outdated": False, "path": "a.js", "line": 1,
    "comments": [
        {"author": "r", "body": "c" * 5000, "url": "thread-at-limit"},
        {"author": "r", "body": "d" * 5001, "url": "thread-over-limit"},
    ],
}], open(sys.argv[1], "w"))
PY
python3 - "$BOUNDARY_DIR/issue-comments.json" << 'PY'
import json, sys
json.dump([
    {"id": 1, "body": "a" * 5000, "user": "h", "created_at": "2026-01-01T00:00:00Z",
     "type": "issue_comment", "html_url": "at-limit"},
    {"id": 2, "body": "b" * 5001, "user": "h", "created_at": "2026-01-02T00:00:00Z",
     "type": "issue_comment", "html_url": "over-limit"},
], open(sys.argv[1], "w"))
PY

"$GH_PR_ENRICH" --test-call build_claude_context "$BOUNDARY_DIR" false >/dev/null 2>&1 || true
BOUNDARY_CTX="$BOUNDARY_DIR/claude-context.json"

assert_jq "$BOUNDARY_CTX" '[.issue_comments[] | select(.url == "at-limit" and (.body | contains("(truncated)")))] | length == 0' \
    "a comment exactly at the limit is not truncated"
assert_jq "$BOUNDARY_CTX" '[.issue_comments[] | select(.url == "over-limit" and (.body | contains("(truncated)")))] | length == 1' \
    "a comment one byte over the limit is truncated"
assert_jq "$BOUNDARY_CTX" '.coverage.issue_comments.truncated == ["over-limit"]' \
    "coverage names exactly the truncated comment"
assert_jq "$BOUNDARY_CTX" '[.unresolved_threads[].comments[] | select(.url == "thread-at-limit" and (.body | contains("(truncated)")))] | length == 0' \
    "a nested thread comment exactly at the limit is not truncated"
assert_jq "$BOUNDARY_CTX" '[.unresolved_threads[].comments[] | select(.url == "thread-over-limit" and (.body | contains("(truncated)")))] | length == 1' \
    "a nested thread comment one byte over the limit is truncated"
assert_jq "$BOUNDARY_CTX" '.coverage.unresolved_threads.truncated == ["thread-over-limit"]' \
    "thread coverage names exactly the truncated nested comment"

BOUNDARY_COV_MD="$BOUNDARY_DIR/coverage.md"
"$GH_PR_ENRICH" --test-call generate_coverage_section "$BOUNDARY_CTX" "$BOUNDARY_COV_MD" >/dev/null 2>&1 || true
assert_contains "$(cat "$BOUNDARY_COV_MD" 2>/dev/null || echo "")" \
    "nested comments truncated: 1" \
    "rendered thread coverage counts truncated nested comments"

# Commit and linked-issue bodies use the same explicit truncation contract as
# comments and diffs; otherwise omitted intent could still certify a clean PR.
INTENT_DIR="$TEST_OUTPUT_DIR/intent-truncation"
mkdir -p "$INTENT_DIR"
cp "$BOUNDARY_DIR/issue-comments.json" "$INTENT_DIR/issue-comments.json"
cp "$BOUNDARY_DIR/unresolved-threads.json" "$INTENT_DIR/unresolved-threads.json"
jq '.body = "PR description beyond five"
    | .commits[0].messageBody = "commit body beyond five"' \
    "$CTX_DIR/pr-summary.json" > "$INTENT_DIR/pr-summary.json"
printf '%s\n' \
    '[{"number":42,"title":"intent","body":"linked issue body beyond five","url":"https://gh/42"}]' \
    > "$INTENT_DIR/linked-issues.json"
GH_PR_ENRICH_TRUNCATE_CHARS=5 "$GH_PR_ENRICH" --test-call \
    build_claude_context "$INTENT_DIR" false >/dev/null 2>&1
INTENT_CTX="$INTENT_DIR/analysis-context.json"
assert_jq "$INTENT_CTX" \
    '(.pr.body | contains("(truncated)")) and
     (.coverage.pr_description.truncated == ["PR description"])' \
    "truncated PR intent is marked in content and coverage"
assert_jq "$INTENT_CTX" \
    '(.pr.commits[0].message | contains("(truncated)")) and
     (.coverage.commits.truncated == ["abc123d"])' \
    "truncated commit intent is marked in content and coverage"
assert_jq "$INTENT_CTX" \
    '.pr.linked_issues[0].body | contains("(truncated)")' \
    "truncated linked-issue intent carries an inline marker"
assert_jq "$INTENT_CTX" \
    '.coverage.linked_issues.truncated == ["https://gh/42"]' \
    "coverage identifies the linked issue whose body was truncated"

FAILED_LINKED_COVERAGE_CTX="$INTENT_DIR/failed-linked-context.json"
jq '.coverage.sources.linked_issues = {
        requested:true,status:"failed",reason:"fixture pagination failure"
    }' "$INTENT_CTX" > "$FAILED_LINKED_COVERAGE_CTX"
FAILED_LINKED_COVERAGE_MD="$INTENT_DIR/failed-linked-coverage.md"
"$GH_PR_ENRICH" --test-call generate_coverage_section \
    "$FAILED_LINKED_COVERAGE_CTX" "$FAILED_LINKED_COVERAGE_MD" >/dev/null 2>&1
FAILED_LINKED_COVERAGE_TEXT=$(cat "$FAILED_LINKED_COVERAGE_MD")
assert_contains "$FAILED_LINKED_COVERAGE_TEXT" \
    "| PR description | 1 | 1 body truncated |" \
    "human coverage reports a truncated PR description"
assert_contains "$FAILED_LINKED_COVERAGE_TEXT" \
    "per PR description, comment, thread reply, commit body, linked issue body and file diff" \
    "coverage documents every text input governed by the truncation limit"
assert_contains "$FAILED_LINKED_COVERAGE_TEXT" \
    "fetch failed: fixture pagination failure" \
    "linked-issue coverage renders its failed source status"
assert_not_contains "$FAILED_LINKED_COVERAGE_TEXT" "all pages fetched" \
    "failed linked-issue coverage never claims pagination completed"

INTENT_BOUNDARY_DIR="$TEST_OUTPUT_DIR/intent-boundary"
mkdir -p "$INTENT_BOUNDARY_DIR"
echo '[]' > "$INTENT_BOUNDARY_DIR/issue-comments.json"
echo '[]' > "$INTENT_BOUNDARY_DIR/unresolved-threads.json"
jq '.body = "abcde" | .commits = []' "$CTX_DIR/pr-summary.json" \
    > "$INTENT_BOUNDARY_DIR/pr-summary.json"
echo '[]' > "$INTENT_BOUNDARY_DIR/linked-issues.json"
GH_PR_ENRICH_TRUNCATE_CHARS=5 "$GH_PR_ENRICH" --test-call \
    build_claude_context "$INTENT_BOUNDARY_DIR" false >/dev/null 2>&1
assert_jq "$INTENT_BOUNDARY_DIR/analysis-context.json" \
    '.pr.body == "abcde" and .coverage.pr_description.truncated == []' \
    "a PR description exactly at the configured limit is complete"

# The limit is configurable, and the coverage block reports the configured value.
CUSTOM_DIR="$TEST_OUTPUT_DIR/custom-limit"
mkdir -p "$CUSTOM_DIR"
cp "$BOUNDARY_DIR/pr-summary.json" "$CUSTOM_DIR/pr-summary.json"
cp "$BOUNDARY_DIR/issue-comments.json" "$CUSTOM_DIR/issue-comments.json"
cp "$BOUNDARY_DIR/unresolved-threads.json" "$CUSTOM_DIR/unresolved-threads.json"

GH_PR_ENRICH_TRUNCATE_CHARS=100 "$GH_PR_ENRICH" --test-call build_claude_context "$CUSTOM_DIR" false >/dev/null 2>&1 || true
assert_jq_eq "$CUSTOM_DIR/claude-context.json" '.coverage.truncation_limit_chars' "100" \
    "GH_PR_ENRICH_TRUNCATE_CHARS changes the reported limit"
assert_jq "$CUSTOM_DIR/claude-context.json" '[.issue_comments[] | select(.body | contains("(truncated)"))] | length == 2' \
    "a lower limit truncates comments that were previously untouched"
assert_jq_eq "$CUSTOM_DIR/claude-context.json" \
    '[.unresolved_threads[].comments[] | select(.body | contains("(truncated)"))] | length' "2" \
    "a lower limit also truncates nested thread comments"
assert_jq "$CUSTOM_DIR/claude-context.json" \
    '.coverage.unresolved_threads.truncated == ["thread-at-limit", "thread-over-limit"]' \
    "thread coverage follows the configured truncation limit"

# Explicit invalid limits fail by name before the builder creates or mutates
# context artifacts. This prevents non-numeric and oversized values from
# reaching jq --argjson as cryptic parser errors.
INVALID_LIMITS=(nope 0 -1 100001 999999999999999999999999999999 \
    1.5 01 " 1" "1 " null true)
INVALID_LIMIT_INDEX=0
for INVALID_LIMIT in "${INVALID_LIMITS[@]}"; do
    INVALID_LIMIT_INDEX=$((INVALID_LIMIT_INDEX + 1))
    INVALID_LIMIT_DIR="$TEST_OUTPUT_DIR/invalid-limit-$INVALID_LIMIT_INDEX"
    mkdir -p "$INVALID_LIMIT_DIR"
    cp "$BOUNDARY_DIR/pr-summary.json" "$INVALID_LIMIT_DIR/pr-summary.json"
    cp "$BOUNDARY_DIR/issue-comments.json" "$INVALID_LIMIT_DIR/issue-comments.json"
    cp "$BOUNDARY_DIR/unresolved-threads.json" "$INVALID_LIMIT_DIR/unresolved-threads.json"
    rc=0
    INVALID_LIMIT_OUT=$(env GH_PR_ENRICH_TRUNCATE_CHARS="$INVALID_LIMIT" \
        "$GH_PR_ENRICH" --test-call build_claude_context \
        "$INVALID_LIMIT_DIR" false 2>&1) || rc=$?
    assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
        "invalid truncation limit '$INVALID_LIMIT' is rejected"
    assert_contains "$INVALID_LIMIT_OUT" "GH_PR_ENRICH_TRUNCATE_CHARS" \
        "invalid truncation limit '$INVALID_LIMIT' names the environment variable"
    assert_not_contains "$INVALID_LIMIT_OUT" "invalid JSON text passed to --argjson" \
        "invalid truncation limit '$INVALID_LIMIT' does not leak a jq parser error"
    assert_true "$([ ! -e "$INVALID_LIMIT_DIR/claude-context.json" ] && echo 0 || echo 1)" \
        "invalid truncation limit '$INVALID_LIMIT' does not publish a context artifact"
done

for VALID_LIMIT in 1 100000; do
    VALID_LIMIT_DIR="$TEST_OUTPUT_DIR/valid-limit-$VALID_LIMIT"
    mkdir -p "$VALID_LIMIT_DIR"
    cp "$BOUNDARY_DIR/pr-summary.json" "$VALID_LIMIT_DIR/pr-summary.json"
    cp "$BOUNDARY_DIR/issue-comments.json" "$VALID_LIMIT_DIR/issue-comments.json"
    cp "$BOUNDARY_DIR/unresolved-threads.json" "$VALID_LIMIT_DIR/unresolved-threads.json"
    GH_PR_ENRICH_TRUNCATE_CHARS="$VALID_LIMIT" "$GH_PR_ENRICH" --test-call \
        build_claude_context "$VALID_LIMIT_DIR" false >/dev/null
    assert_jq_eq "$VALID_LIMIT_DIR/claude-context.json" \
        '.coverage.truncation_limit_chars' "$VALID_LIMIT" \
        "truncation limit boundary '$VALID_LIMIT' is accepted"
done

EMPTY_LIMIT_DIR="$TEST_OUTPUT_DIR/empty-limit"
mkdir -p "$EMPTY_LIMIT_DIR"
cp "$BOUNDARY_DIR/pr-summary.json" "$EMPTY_LIMIT_DIR/pr-summary.json"
cp "$BOUNDARY_DIR/issue-comments.json" "$EMPTY_LIMIT_DIR/issue-comments.json"
cp "$BOUNDARY_DIR/unresolved-threads.json" "$EMPTY_LIMIT_DIR/unresolved-threads.json"
GH_PR_ENRICH_TRUNCATE_CHARS='' "$GH_PR_ENRICH" --test-call \
    build_claude_context "$EMPTY_LIMIT_DIR" false >/dev/null
assert_jq_eq "$EMPTY_LIMIT_DIR/claude-context.json" \
    '.coverage.truncation_limit_chars' "5000" \
    "an explicitly empty truncation limit uses the documented default"

# ---------------------------------------------------------------------------
# Coverage is rendered for humans, not just stored
# ---------------------------------------------------------------------------
COV_MD="$TEST_OUTPUT_DIR/coverage.md"
"$GH_PR_ENRICH" --test-call generate_coverage_section "$CTX" "$COV_MD" >/dev/null 2>&1 || true
COV_TEXT=$(cat "$COV_MD" 2>/dev/null || echo "")

assert_contains "$COV_TEXT" "Analysis Context Coverage" "coverage section has a heading"
assert_contains "$COV_TEXT" "src/retry.js" "coverage section names the truncated file"
assert_contains "$COV_TEXT" "superseded bot reposts dropped" "coverage section reports dropped bot reposts"
assert_contains "$COV_TEXT" "outdated" "coverage section reports outdated threads"

# The "not verified against code" warning keys on the recorded access decision,
# not a second inference from revision fields. An explicit override may grant
# access to a non-matching revision, and that state must render consistently.
warning_for() {
    local state="$1" matches="$2" ctx="$TEST_OUTPUT_DIR/warn-ctx.json" out="$TEST_OUTPUT_DIR/warn.md"
    jq -n --arg state "$state" --argjson matches "$matches" '{
        coverage: {code_access: {state: $state, reason: "test reason", revision_matches: $matches}}
    }' > "$ctx"
    "$GH_PR_ENRICH" --test-call generate_coverage_section "$ctx" "$out" >/dev/null 2>&1 || true
    cat "$out" 2>/dev/null || echo ""
}

assert_not_contains "$(warning_for enabled false)" "could not read the repository" \
    "no warning when access was granted explicitly on a non-matching revision"
assert_contains "$(warning_for disabled false)" "could not read the repository" \
    "a warning when access was actually denied"
assert_not_contains "$(warning_for enabled true)" "could not read the repository" \
    "no warning when the tree is exactly at the PR head"

# Concurrent builders stage fingerprinted contexts privately before taking the
# report lock. The second builder may publish while the first is paused, but it
# cannot overwrite or move the first builder's staging file.
CONCURRENT_CONTEXT_DIR="$TEST_OUTPUT_DIR/concurrent-context"
CONCURRENT_CONTEXT_STUBS="$TEST_OUTPUT_DIR/concurrent-context-stubs"
CONCURRENT_CONTEXT_READY="$TEST_OUTPUT_DIR/concurrent-context.ready"
CONCURRENT_CONTEXT_RELEASE="$TEST_OUTPUT_DIR/concurrent-context.release"
mkdir -p "$CONCURRENT_CONTEXT_DIR" "$CONCURRENT_CONTEXT_STUBS"
jq -n '{number:77,title:"concurrent",body:"abcdefghijk",
    author:{login:"dev"},files:[],commits:[],headRefOid:""}' \
    > "$CONCURRENT_CONTEXT_DIR/pr-summary.json"
echo '[]' > "$CONCURRENT_CONTEXT_DIR/issue-comments.json"
echo '[]' > "$CONCURRENT_CONTEXT_DIR/unresolved-threads.json"
cat > "$CONCURRENT_CONTEXT_STUBS/jq" << 'STUB'
#!/bin/bash
is_fingerprint=false
previous=""
for argument in "$@"; do
    if [ "$previous" = "--arg" ] && [ "$argument" = "fingerprint" ]; then
        is_fingerprint=true
    fi
    previous="$argument"
done
"$REAL_JQ" "$@" || exit $?
if [ "$is_fingerprint" = true ] && [ ! -f "$CONCURRENT_CONTEXT_READY" ]; then
    : > "$CONCURRENT_CONTEXT_READY"
    while [ ! -f "$CONCURRENT_CONTEXT_RELEASE" ]; do /bin/sleep 0.01; done
fi
STUB
chmod +x "$CONCURRENT_CONTEXT_STUBS/jq"
env PATH="$CONCURRENT_CONTEXT_STUBS:$PATH" REAL_JQ="$(command -v jq)" \
    CONCURRENT_CONTEXT_READY="$CONCURRENT_CONTEXT_READY" \
    CONCURRENT_CONTEXT_RELEASE="$CONCURRENT_CONTEXT_RELEASE" \
    GH_PR_ENRICH_TRUNCATE_CHARS=5 \
    "$GH_PR_ENRICH" --test-call build_claude_context \
    "$CONCURRENT_CONTEXT_DIR" false >/dev/null 2>&1 &
CONCURRENT_FIRST_PID=$!
for (( _attempt=0; _attempt < 200; _attempt++ )); do
    [ -f "$CONCURRENT_CONTEXT_READY" ] && break
    /bin/sleep 0.01
done
assert_true "$([ -f "$CONCURRENT_CONTEXT_READY" ] && echo 0 || echo 1)" \
    "the first context builder pauses after private fingerprint staging"
GH_PR_ENRICH_TRUNCATE_CHARS=9 "$GH_PR_ENRICH" --test-call \
    build_claude_context "$CONCURRENT_CONTEXT_DIR" false >/dev/null
: > "$CONCURRENT_CONTEXT_RELEASE"
rc=0
wait "$CONCURRENT_FIRST_PID" || rc=$?
assert_true "$rc" \
    "a concurrent context publication cannot steal another builder's staging file"
assert_jq "$CONCURRENT_CONTEXT_DIR/analysis-context.json" \
    '.coverage.truncation_limit_chars == 5 and
     (.coverage.context_fingerprint | type == "string" and length > 0)' \
    "the resumed builder publishes its own complete fingerprinted context"
CONCURRENT_CONTEXT_FINGERPRINT=$("$GH_PR_ENRICH" --test-call \
    analysis_context_fingerprint "$CONCURRENT_CONTEXT_DIR/analysis-context.json")
rc=0
jq -e --arg fingerprint "$CONCURRENT_CONTEXT_FINGERPRINT" \
    '.coverage.context_fingerprint == $fingerprint' \
    "$CONCURRENT_CONTEXT_DIR/analysis-context.json" >/dev/null 2>&1 || rc=$?
assert_true "$rc" \
    "the final concurrent context fingerprint matches its exact bytes"
assert_true "$([ ! -e "$CONCURRENT_CONTEXT_DIR/analysis-context.tmp.json" ] && \
    [ ! -e "$CONCURRENT_CONTEXT_DIR/analysis-context.fingerprinted.tmp.json" ] && \
    ! find "$CONCURRENT_CONTEXT_DIR" -maxdepth 1 \
        -name '.analysis-context-publish.*' -print -quit | grep -q . && \
    echo 0 || echo 1)" \
    "concurrent context builders leave no shared or unique staging residue"

# ---------------------------------------------------------------------------
# Large inputs: a big PR must not blow the argument list
#
# pr-diff.json carries the whole raw diff plus per-file copies, so on a large PR
# it runs to megabytes. Passing it through argv fails with E2BIG ("Argument list
# too long") — and it fails on exactly the PRs that most need analysis.
# ---------------------------------------------------------------------------
BIG_DIR="$TEST_OUTPUT_DIR/big"
mkdir -p "$BIG_DIR"
cp "$UNRESOLVED" "$BIG_DIR/unresolved-threads.json"
echo '[]' > "$BIG_DIR/issue-comments.json"

python3 - "$BIG_DIR" << 'PY'
import json, sys, pathlib

out = pathlib.Path(sys.argv[1])

# ~4 MB of diff across many files, and a PR summary with many files and commits.
chunk = "diff --git a/src/f%d.js b/src/f%d.js\n" + ("+ padding line to make this file diff large\n" * 900)
file_diffs = [{"file": "src/f%d.js" % i, "content": chunk % (i, i)} for i in range(60)]
raw = "".join(d["content"] for d in file_diffs)
(out / "pr-diff.json").write_text(json.dumps({"raw_diff": raw, "file_diffs": file_diffs}))

(out / "pr-summary.json").write_text(json.dumps({
    "number": 500,
    "title": "Large change",
    "body": "x" * 20000,
    "author": {"login": "dev"},
    "files": [{"path": "src/f%d.js" % i} for i in range(60)],
    "commits": [{"oid": "%040d" % i,
                 "messageHeadline": "commit %d" % i,
                 "messageBody": "body " * 200} for i in range(150)],
}))
PY

BIG_BYTES=$(wc -c < "$BIG_DIR/pr-diff.json" | tr -d ' ')
rc=0
BIG_ERR=$("$GH_PR_ENRICH" --test-call build_claude_context "$BIG_DIR" true 2>&1) || rc=$?

assert_true "$rc" "context builds from a multi-megabyte diff (${BIG_BYTES} bytes)" "$BIG_ERR"
assert_jq "$BIG_DIR/claude-context.json" '.code_changes.file_diffs | length == 60' \
    "every changed file reaches the context"
assert_jq "$BIG_DIR/claude-context.json" '.pr.commits | length == 150' \
    "every commit reaches the context"
assert_jq "$BIG_DIR/claude-context.json" '.coverage.diff.files_truncated | length == 60' \
    "oversized file diffs are recorded as truncated"

suite_end
