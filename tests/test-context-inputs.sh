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
# Minimal gh stub: emits two pages of reviewThreads for `gh api graphql --paginate`.
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    cat << 'PAGE1'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"CUR1"},"nodes":[
  {"id":"PRRT_page1","isResolved":false,"isOutdated":false,"path":"src/a.js","line":10,
   "comments":{"nodes":[{"id":"c1","databaseId":1,"body":"first page thread","author":{"login":"rev1"},"createdAt":"2026-01-01T00:00:00Z","url":"u1"}]}}
]}}}}}
PAGE1
    cat << 'PAGE2'
{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"PRRT_page2","isResolved":false,"isOutdated":true,"path":"src/b.js","line":20,
   "comments":{"nodes":[{"id":"c2","databaseId":2,"body":"second page thread","author":{"login":"rev2"},"createdAt":"2026-01-02T00:00:00Z","url":"u2"}]}}
]}}}}}
PAGE2
    exit 0
fi
exit 1
STUB
chmod +x "$STUB_DIR/gh"

THREADS="$TEST_OUTPUT_DIR/comment-threads.json"
PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call fetch_review_threads owner repo 1 "$THREADS" >/dev/null 2>&1 || true

assert_jq_eq "$THREADS" '[.data.repository.pullRequest.reviewThreads.nodes[]] | length' "2" \
    "review threads from both pages are merged (pagination works)"
assert_jq "$THREADS" '[.data.repository.pullRequest.reviewThreads.nodes[].id] | index("PRRT_page2") != null' \
    "thread from the second page is not dropped"

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
[{"number": 42, "title": "Requests fail on flaky network", "body": "Users see 500s when upstream is slow.", "url": "https://gh/42"}]
EOF

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
assert_jq_eq "$CTX" '.failing_checks | length' "1" "only failing checks are included"
assert_jq "$CTX" '.failing_checks[0].name == "unit-tests"' "failing check is named"
assert_jq_eq "$CTX" '.sast_findings | length' "1" "sast findings reach the context when present"

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
