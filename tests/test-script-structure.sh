#!/bin/bash
# Structural invariants for the gh-pr-enrich script.
#
# These tests exist because the enrichment functions were once defined INSIDE the
# main-body guard, forcing a hand-maintained copy of build_claude_context for test
# mode. Tests then validated the copy while the shipped function drifted. These
# checks make that class of defect impossible to reintroduce.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GH_PR_ENRICH="$PROJECT_DIR/gh-pr-enrich"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output/structure"

# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

cleanup() { rm -rf "$TEST_OUTPUT_DIR"; }
trap cleanup EXIT

suite_start "gh-pr-enrich script structure suite"

setup() {
    cleanup
    mkdir -p "$TEST_OUTPUT_DIR"
}
setup

# ---------------------------------------------------------------------------
# Syntax
# ---------------------------------------------------------------------------
rc=0; bash -n "$GH_PR_ENRICH" 2>/dev/null || rc=$?
assert_true "$rc" "script parses cleanly (bash -n)"
assert_contains "$(cat "$SCRIPT_DIR/run-all.sh")" \
    'output=$(bash "$suite" 2>&1)' \
    "the aggregate runner does not require executable suite files"

# ---------------------------------------------------------------------------
# No duplicated function bodies
# ---------------------------------------------------------------------------
def_count=$(grep -c '^build_analysis_context() ($' "$GH_PR_ENRICH" || true)
assert_eq "1" "$def_count" "build_analysis_context is defined exactly once"

legacy_wrapper_count=$(grep -c '^build_claude_context() {' "$GH_PR_ENRICH" || true)
assert_eq "1" "$legacy_wrapper_count" "the legacy Claude builder name has one thin wrapper"

# The inlined copy was identified by this comment; it must not come back.
inline_marker=$(grep -c 'Inlined version of build_claude_context' "$GH_PR_ENRICH" || true)
assert_eq "0" "$inline_marker" "no inlined copy of build_claude_context remains"

# The context document must be assembled in exactly one place. Two writers means
# one of them is a copy that will drift.
writer_count=$(grep -c '> "$context_tmp"' "$GH_PR_ENRICH" || true)
assert_eq "1" "$writer_count" "analysis-context.json is written by exactly one code path"

compat_copy_count=$(grep -c 'copy_compatibility_file "$output_dir/analysis-context.json" "$output_dir/claude-context.json"' "$GH_PR_ENRICH" || true)
assert_eq "1" "$compat_copy_count" "the legacy Claude context is only a compatibility alias"

# ---------------------------------------------------------------------------
# Generic test dispatcher replaces the special-cased --test-build-context hook
# ---------------------------------------------------------------------------
assert_eq "0" "$(grep -c -- '--test-build-context' "$GH_PR_ENRICH" || true)" \
    "special-cased --test-build-context hook removed"

# Complete comment corpora and PR summaries can exceed the platform argv
# limit. Report assembly must load those JSON documents from files.
assert_eq "0" "$(grep -c -- '--argjson comments' "$GH_PR_ENRICH" || true)" \
    "report generation never passes a comment corpus through argv"
COMMENT_STATS_BODY=$(sed -n \
    '/^COMMENT_STATS_FILE="\$BASE_REPLACEMENT_DIR/,/^for BASE_VIEW/p' \
    "$GH_PR_ENRICH")
assert_contains "$COMMENT_STATS_BODY" '--slurpfile comments_doc' \
    "comment statistics load the complete corpus from a file"
assert_contains "$COMMENT_STATS_BODY" \
    'comments must contain exactly one JSON array' \
    "comment statistics reject empty, multi-document, and non-array JSON"
COMBINED_REPORT_BODY=$(sed -n \
    '/^echo "Creating combined JSON/,/^echo "Creating Markdown report/p' \
    "$GH_PR_ENRICH")
assert_contains "$COMBINED_REPORT_BODY" '--slurpfile comments_doc' \
    "combined report generation loads comments from a file"
assert_contains "$COMBINED_REPORT_BODY" 'must contain exactly one JSON document' \
    "file-backed report inputs reject empty and multi-document JSON"
assert_eq "0" "$(grep -c -- '--arg diff' "$GH_PR_ENRICH" || true)" \
    "diff normalization never passes a complete diff through argv"
assert_contains "$(sed -n '/^fetch_pr_diff() {/,/^}/p' "$GH_PR_ENRICH")" \
    '--rawfile diff' "diff normalization loads the complete diff from a file"

# This helper runs for every inventoried path. Ancestor traversal must stay in
# the shell instead of spawning one dirname process per path component.
SYMLINK_COMPONENT_BODY=$(sed -n \
    '/^path_has_symlink_component() {/,/^}/p' "$GH_PR_ENRICH")
assert_contains "$SYMLINK_COMPONENT_BODY" '${probe%/*}' \
    "symlink ancestor traversal uses shell parameter expansion"
assert_not_contains "$SYMLINK_COMPONENT_BODY" 'dirname' \
    "symlink ancestor traversal does not fork per path component"

DATE_FILTER_DIR="$TEST_OUTPUT_DIR/retrospective-dates"
mkdir -p "$DATE_FILTER_DIR"
cat > "$DATE_FILTER_DIR/recent.json" << 'EOF'
{"createdAt":"2026-08-20T12:34:56Z"}
EOF
assert_eq "2026-08-20" \
    "$("$GH_PR_ENRICH" --test-call retrospective_report_date \
        "$DATE_FILTER_DIR/recent.json")" \
    "retrospective dates accept a complete recent GitHub timestamp"
cat > "$DATE_FILTER_DIR/fallback.json" << 'EOF'
{"createdAt":"not-a-date","updatedAt":"2026-07-15T01:02:03Z"}
EOF
assert_eq "2026-07-15" \
    "$("$GH_PR_ENRICH" --test-call retrospective_report_date \
        "$DATE_FILTER_DIR/fallback.json")" \
    "retrospective dates fall back to a valid updatedAt"
cat > "$DATE_FILTER_DIR/old.json" << 'EOF'
{"createdAt":"2025-01-02T03:04:05Z"}
EOF
assert_eq "2025-01-02" \
    "$("$GH_PR_ENRICH" --test-call retrospective_report_date \
        "$DATE_FILTER_DIR/old.json")" \
    "retrospective dates preserve an old report date for cutoff comparison"
cat > "$DATE_FILTER_DIR/invalid.json" << 'EOF'
{"createdAt":"2026-02-30T00:00:00Z","updatedAt":null}
EOF
rc=0
"$GH_PR_ENRICH" --test-call retrospective_report_date \
    "$DATE_FILTER_DIR/invalid.json" > /dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "retrospective dates reject impossible calendar dates"
cat > "$DATE_FILTER_DIR/missing.json" << 'EOF'
{"number":1}
EOF
rc=0
"$GH_PR_ENRICH" --test-call retrospective_report_date \
    "$DATE_FILTER_DIR/missing.json" > /dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "retrospective dates reject summaries without timestamps"
rc=0
"$GH_PR_ENRICH" --test-call retrospective_report_date \
    "$DATE_FILTER_DIR/absent.json" > /dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "retrospective dates reject missing summaries"
touch "$DATE_FILTER_DIR/empty.json"
rc=0
"$GH_PR_ENRICH" --test-call retrospective_report_date \
    "$DATE_FILTER_DIR/empty.json" > /dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "retrospective dates reject an empty summary"
cat > "$DATE_FILTER_DIR/multiple.json" << 'EOF'
{"createdAt":"2026-08-20T12:34:56Z"}
{"createdAt":"2026-08-21T12:34:56Z"}
EOF
rc=0
"$GH_PR_ENRICH" --test-call retrospective_report_date \
    "$DATE_FILTER_DIR/multiple.json" > /dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "retrospective dates reject multiple JSON documents"
cat > "$DATE_FILTER_DIR/non-object.json" << 'EOF'
["2026-08-20T12:34:56Z"]
EOF
rc=0
"$GH_PR_ENRICH" --test-call retrospective_report_date \
    "$DATE_FILTER_DIR/non-object.json" > /dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "retrospective dates reject a non-object summary"
rc=0
grep -F 'skipped_unknown_date++' "$GH_PR_ENRICH" > /dev/null || rc=$?
assert_true "$rc" \
    "retrospective --since excludes and counts unverifiable dates"

ADDRESS_MODE_BODY=$(sed -n \
    '/^if \[ "\$1" = "address" \]; then/,/^# Handle --help flag/p' \
    "$GH_PR_ENRICH")
assert_contains "$ADDRESS_MODE_BODY" 'prepare_address_expected_discussion' \
    "address mode anchors a complete captured discussion snapshot"
assert_contains "$ADDRESS_MODE_BODY" \
    'verify_address_analysis_discussion_unchanged' \
    "address mode revalidates the complete discussion around mutations"
assert_contains "$(sed -n \
    '/^verify_address_analysis_discussion_unchanged() {/,/^}/p' \
    "$GH_PR_ENRICH")" 'ADDRESS_HOSTED_TIMEOUT_MULTIPLIER=8' \
    "complete discussion verification receives an eight-request budget"
assert_contains "$ADDRESS_MODE_BODY" \
    'mark_address_expected_discussion_resolved' \
    "address mode records only its confirmed resolution in expected state"
ADDRESS_DISCUSSION_UPDATE_BODY=$(sed -n \
    '/^mark_address_expected_discussion_resolved() {/,/^}/p' \
    "$GH_PR_ENRICH")
assert_contains "$ADDRESS_DISCUSSION_UPDATE_BODY" '.is_resolved = true' \
    "owned discussion updates change only the resolved field"
assert_contains "$ADDRESS_DISCUSSION_UPDATE_BODY" 'jq -cS -e' \
    "owned discussion updates preserve canonical snapshot bytes"

# Dispatcher invokes the real function.
mkdir -p "$TEST_OUTPUT_DIR/ctx"
cat > "$TEST_OUTPUT_DIR/ctx/pr-summary.json" << 'EOF'
{"number": 1, "title": "t", "body": "b", "author": {"login": "u"}, "files": [{"path": "a.js"}]}
EOF
echo '[]' > "$TEST_OUTPUT_DIR/ctx/unresolved-threads.json"
echo '[]' > "$TEST_OUTPUT_DIR/ctx/issue-comments.json"

rc=0
"$GH_PR_ENRICH" --test-call build_claude_context "$TEST_OUTPUT_DIR/ctx" > /dev/null 2>&1 || rc=$?
assert_true "$rc" "--test-call dispatches build_claude_context"
assert_jq "$TEST_OUTPUT_DIR/ctx/claude-context.json" '.pr.title == "t"' \
    "dispatched function produced a valid context file"
assert_jq "$TEST_OUTPUT_DIR/ctx/analysis-context.json" '.pr.title == "t"' \
    "dispatched function produced the provider-neutral context file"

# A fired report watchdog can retain its command PID through the TERM-to-KILL
# grace period. The command supervisor must stay alive until the owner stops the
# watcher, anchoring the numeric process-group identity through any delayed KILL.
RUN_REPORT_COMMAND_BODY=$(sed -n '/^run_report_command() {/,/^}/p' "$GH_PR_ENRICH")
assert_contains "$RUN_REPORT_COMMAND_BODY" 'if [ "$supervisor_signalled" = true ]' \
    "report supervisors stay alive after receiving a timeout signal"
assert_contains "$RUN_REPORT_COMMAND_BODY" ': > "$watchdog_control_dir/completed"' \
    "report supervisors publish completion before waiting for owner release"
assert_contains "$RUN_REPORT_COMMAND_BODY" \
    ': > "$watchdog_control_dir/supervisor-ready"' \
    "report supervisors announce readiness before command launch"
assert_contains "$RUN_REPORT_COMMAND_BODY" ': > "$watchdog_control_dir/start"' \
    "report owners acknowledge isolated process groups before command launch"
assert_contains "$RUN_REPORT_COMMAND_BODY" \
    '[ ! -e "$watchdog_control_dir/watchdog-exited" ]' \
    "completed supervisors wait for confirmed watchdog exit"
assert_contains "$RUN_REPORT_COMMAND_BODY" ': > "$watchdog_control_dir/release"' \
    "report owners release completed supervisors before stopping the watchdog"
assert_not_contains "$RUN_REPORT_COMMAND_BODY" 'kill -USR1' \
    "report watchdogs do not repurpose a process-wide application signal"
assert_not_contains "$RUN_REPORT_COMMAND_BODY" 'kill -TERM "$command_pid"' \
    "report watchdogs have no PID-only fallback for unowned command groups"
assert_not_contains "$RUN_REPORT_COMMAND_BODY" 'kill -KILL "$command_pid"' \
    "report escalation has no PID-only fallback for unowned command groups"
STOP_REPORT_WATCHDOG_BODY=$(sed -n '/^stop_report_run_watchdog() {/,/^}/p' \
    "$GH_PR_ENRICH")
assert_contains "$STOP_REPORT_WATCHDOG_BODY" \
    ': > "$REPORT_RUN_WATCHDOG_CONTROL_DIR/watchdog-release"' \
    "report owners release watchdogs before waiting for them"
assert_not_contains "$STOP_REPORT_WATCHDOG_BODY" \
    'kill -TERM "$REPORT_RUN_WATCHDOG_PID"' \
    "report owners never signal a saved numeric watchdog PID"
TERMINATE_REPORT_CHILD_BODY=$(sed -n \
    '/^terminate_report_run_child() {/,/^}/p' "$GH_PR_ENRICH")
assert_contains "$TERMINATE_REPORT_CHILD_BODY" \
    'terminate_report_run_watchdog' \
    "cancellation delegates escalation to the command watchdog"
TERMINATE_REAP_LINE=$(printf '%s\n' "$TERMINATE_REPORT_CHILD_BODY" | \
    grep -n '^    wait "\$command_pid"' | cut -d: -f1)
TERMINATE_WATCHDOG_LINE=$(printf '%s\n' "$TERMINATE_REPORT_CHILD_BODY" | \
    grep -n 'terminate_report_run_watchdog' | cut -d: -f1)
assert_true "$([ -n "$TERMINATE_WATCHDOG_LINE" ] && \
    [ "$TERMINATE_WATCHDOG_LINE" -lt "$TERMINATE_REAP_LINE" ] && \
    echo 0 || echo 1)" \
    "cancellation stops its signalling owner before reaping the PGID anchor"

# Semgrep uses the same identity-safe handoff: its group leader publishes
# completion, then remains alive until the owner releases it and the only
# numeric signal owner has confirmed exit.
SEMGREP_WATCHDOG_BODY=$(sed -n \
    '/^run_semgrep_with_watchdog() {/,/^collect_sast_findings() {/p' \
    "$GH_PR_ENRICH")
assert_contains "$SEMGREP_WATCHDOG_BODY" ': > "$launch_dir/completed"' \
    "the Semgrep supervisor publishes scanner completion"
assert_contains "$SEMGREP_WATCHDOG_BODY" \
    '[ ! -e "$launch_dir/watchdog-exited" ]' \
    "the Semgrep supervisor anchors its PGID until watchdog exit"
assert_contains "$SEMGREP_WATCHDOG_BODY" \
    ': > "$semgrep_launch_dir/supervisor-release"' \
    "the Semgrep owner releases a completed supervisor before reaping it"
assert_contains "$SEMGREP_WATCHDOG_BODY" \
    ': > "$watchdog_launch_dir/watchdog-release"' \
    "the Semgrep owner stops its watchdog through private control state"
assert_contains "$SEMGREP_WATCHDOG_BODY" \
    ': > "$semgrep_launch_dir/start"' \
    "the Semgrep owner releases scanner and watchdog through one shared gate"
assert_contains "$SEMGREP_WATCHDOG_BODY" \
    '[ "$gate_attempt" -lt 500 ]' \
    "Semgrep launch gates are bounded if their owner disappears"
assert_not_contains "$SEMGREP_WATCHDOG_BODY" \
    'kill -TERM "$watchdog_pid"' \
    "the Semgrep owner never signals a saved numeric watchdog PID"

# Inventory every non-directory entry without opening it. A generated filename
# is not safe merely because it is allowlisted when its inode is a FIFO, socket,
# device, or another non-regular type.
SPECIAL_OUTPUT_DIR="$TEST_OUTPUT_DIR/special-output"
mkdir -p "$SPECIAL_OUTPUT_DIR"
mkfifo "$SPECIAL_OUTPUT_DIR/checks.json"
rc=0
SPECIAL_OUTPUT_OUT=$("$GH_PR_ENRICH" --test-call \
    validate_output_directory_for_writes "$SPECIAL_OUTPUT_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "report preflight rejects an allowlisted FIFO without opening it"
assert_contains "$SPECIAL_OUTPUT_OUT" "non-regular file: checks.json" \
    "special-file rejection identifies the unsafe generated artifact"

# A regular generated file can still alias unrelated content through a hard
# link. Preflight must fail before any report redirection truncates that inode.
HARDLINK_OUTPUT_DIR="$TEST_OUTPUT_DIR/hardlink-output"
HARDLINK_SENTINEL="$TEST_OUTPUT_DIR/hardlink-sentinel"
mkdir -p "$HARDLINK_OUTPUT_DIR"
printf 'preserve-me\n' > "$HARDLINK_SENTINEL"
ln "$HARDLINK_SENTINEL" "$HARDLINK_OUTPUT_DIR/checks.json"
rc=0
HARDLINK_OUTPUT_OUT=$("$GH_PR_ENRICH" --test-call \
    validate_output_directory_for_writes "$HARDLINK_OUTPUT_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "report preflight rejects an allowlisted hard-linked file"
assert_contains "$HARDLINK_OUTPUT_OUT" "hard-linked file: checks.json" \
    "hard-link rejection identifies the unsafe generated artifact"
assert_eq "preserve-me" "$(cat "$HARDLINK_SENTINEL")" \
    "hard-link rejection preserves the unrelated inode contents"

# Automatic code access also inventories an ignored report directory before
# excluding it from cleanliness checks. A generated name sharing a tracked
# source inode must disable that exclusion.
HARDLINK_REPO="$TEST_OUTPUT_DIR/hardlink-repo"
mkdir -p "$HARDLINK_REPO/report"
(cd "$HARDLINK_REPO" && git init -q . && \
    git config user.email t@t && git config user.name t && \
    git config commit.gpgsign false && \
    printf 'report/\n' > .gitignore && printf 'source\n' > tracked.txt && \
    git add .gitignore tracked.txt && git commit -qm init)
ln "$HARDLINK_REPO/tracked.txt" "$HARDLINK_REPO/report/checks.json"
HARDLINK_HEAD=$(git -C "$HARDLINK_REPO" rev-parse HEAD)
HARDLINK_ACCESS=$( (cd "$HARDLINK_REPO" && \
    "$GH_PR_ENRICH" --test-call resolve_code_access "$HARDLINK_HEAD" \
        "$HARDLINK_REPO/report" 2>&1) || true)
assert_contains "$HARDLINK_ACCESS" "disabled" \
    "automatic code access rejects a generated name hard-linked to tracked source"
assert_contains "$HARDLINK_ACCESS" "uncommitted or untracked files" \
    "hard-linked output is treated as unsafe local workspace state"

# Exercise the natural-completion handshake directly with a fast scanner stub.
SEMGREP_STUB_DIR="$TEST_OUTPUT_DIR/semgrep-stubs"
SEMGREP_RAW="$TEST_OUTPUT_DIR/semgrep-raw.json"
SEMGREP_STDERR="$TEST_OUTPUT_DIR/semgrep.stderr"
SEMGREP_SNAPSHOT=$(mktemp -d /tmp/gh-pr-enrich-code-snapshot.XXXXXX)
SEMGREP_BOUNDARY_ENV="$TEST_OUTPUT_DIR/semgrep-boundary-env"
SEMGREP_BOUNDARY_WATCHDOG_PID="$TEST_OUTPUT_DIR/semgrep-boundary-watchdog.pid"
SEMGREP_BOUNDARY_JOBS="$TEST_OUTPUT_DIR/semgrep-boundary.jobs"
SEMGREP_BOUNDARY_REACHED="$TEST_OUTPUT_DIR/semgrep-boundary.reached"
SEMGREP_BOUNDARY_UNSAFE_SIGNAL="$TEST_OUTPUT_DIR/semgrep-boundary-unsafe-signal"
mkdir -p "$SEMGREP_STUB_DIR"
cat > "$SEMGREP_STUB_DIR/semgrep" << 'STUB'
#!/bin/sh
printf '{"results":[],"errors":[]}\n'
STUB
chmod +x "$SEMGREP_STUB_DIR/semgrep"
cat > "$SEMGREP_BOUNDARY_ENV" << 'STUB'
__gh_pr_enrich_semgrep_completion_debug() {
    case "$BASH_COMMAND" in
        'kill -TERM -- "-$semgrep_pid"'*|'kill -KILL -- "-$semgrep_pid"'*)
            printf 'unsafe\n' > "$SEMGREP_BOUNDARY_UNSAFE_SIGNAL"
            ;;
        'watchdog_pid=$!')
            [ -e "$SEMGREP_BOUNDARY_WATCHDOG_PID" ] || \
                printf '%s\n' "$!" > "$SEMGREP_BOUNDARY_WATCHDOG_PID"
            ;;
        'semgrep_pid=$!') ;;
        semgrep_pid=*)
            [ -e "$SEMGREP_BOUNDARY_REACHED" ] && return 0
            printf 'reached\n' > "$SEMGREP_BOUNDARY_REACHED"
            jobs -r -p > "$SEMGREP_BOUNDARY_JOBS"
            ;;
        'semgrep_reaping=false')
            if [ "${SEMGREP_BOUNDARY_SIGNAL_POINT:-}" = reaping-clear ] && \
               [ ! -e "$SEMGREP_BOUNDARY_SIGNAL_SENT" ]; then
                printf 'sent\n' > "$SEMGREP_BOUNDARY_SIGNAL_SENT"
                /bin/sh -c 'kill -TERM "$PPID"'
            fi
            ;;
    esac
}
set -T
trap '__gh_pr_enrich_semgrep_completion_debug' DEBUG
STUB
rc=0
BASH_ENV="$SEMGREP_BOUNDARY_ENV" \
    SEMGREP_BOUNDARY_WATCHDOG_PID="$SEMGREP_BOUNDARY_WATCHDOG_PID" \
    SEMGREP_BOUNDARY_JOBS="$SEMGREP_BOUNDARY_JOBS" \
    SEMGREP_BOUNDARY_REACHED="$SEMGREP_BOUNDARY_REACHED" \
    SEMGREP_BOUNDARY_UNSAFE_SIGNAL="$SEMGREP_BOUNDARY_UNSAFE_SIGNAL" \
    PATH="$SEMGREP_STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call \
        run_semgrep_with_watchdog 2 "$SEMGREP_RAW" "$SEMGREP_STDERR" \
        auto "$SEMGREP_SNAPSHOT" . || rc=$?
assert_true "$rc" "a fast Semgrep run completes through the watchdog handoff"
assert_contains "$(cat "$SEMGREP_RAW")" '"results":[]' \
    "the Semgrep watchdog handoff preserves scanner output"
SEMGREP_BOUNDARY_PID=$(cat "$SEMGREP_BOUNDARY_WATCHDOG_PID" 2>/dev/null || echo "")
assert_true "$([ -s "$SEMGREP_BOUNDARY_REACHED" ] && \
    [ -n "$SEMGREP_BOUNDARY_PID" ] && echo 0 || echo 1)" \
    "the Semgrep fixture reaches the supervisor-reap boundary"
assert_true "$([ -f "$SEMGREP_BOUNDARY_JOBS" ] && \
    ! grep -Fx "$SEMGREP_BOUNDARY_PID" "$SEMGREP_BOUNDARY_JOBS" >/dev/null 2>&1 && \
    echo 0 || echo 1)" \
    "the Semgrep watchdog is not running when the PGID anchor is cleared"
rmdir "$SEMGREP_SNAPSHOT"

# A signal at that exact boundary must be deferred until the wait-only reap is
# complete. It must not re-enter numeric process-group termination after the
# watchdog has exited.
SEMGREP_SIGNAL_RAW="$TEST_OUTPUT_DIR/semgrep-signal-raw.json"
SEMGREP_SIGNAL_STDERR="$TEST_OUTPUT_DIR/semgrep-signal.stderr"
SEMGREP_SIGNAL_SNAPSHOT=$(mktemp -d /tmp/gh-pr-enrich-code-snapshot.XXXXXX)
SEMGREP_SIGNAL_TMP=$(mktemp -d /tmp/gh-pr-enrich-semgrep-test.XXXXXX)
SEMGREP_BOUNDARY_SIGNAL_SENT="$TEST_OUTPUT_DIR/semgrep-boundary-signal.sent"
rm -f "$SEMGREP_BOUNDARY_REACHED" "$SEMGREP_BOUNDARY_JOBS" \
    "$SEMGREP_BOUNDARY_WATCHDOG_PID" "$SEMGREP_BOUNDARY_UNSAFE_SIGNAL" \
    "$SEMGREP_BOUNDARY_SIGNAL_SENT"
rc=0
BASH_ENV="$SEMGREP_BOUNDARY_ENV" \
    TMPDIR="$SEMGREP_SIGNAL_TMP" \
    SEMGREP_BOUNDARY_SIGNAL_POINT=reaping-clear \
    SEMGREP_BOUNDARY_SIGNAL_SENT="$SEMGREP_BOUNDARY_SIGNAL_SENT" \
    SEMGREP_BOUNDARY_WATCHDOG_PID="$SEMGREP_BOUNDARY_WATCHDOG_PID" \
    SEMGREP_BOUNDARY_JOBS="$SEMGREP_BOUNDARY_JOBS" \
    SEMGREP_BOUNDARY_REACHED="$SEMGREP_BOUNDARY_REACHED" \
    SEMGREP_BOUNDARY_UNSAFE_SIGNAL="$SEMGREP_BOUNDARY_UNSAFE_SIGNAL" \
    PATH="$SEMGREP_STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call \
        run_semgrep_with_watchdog 2 "$SEMGREP_SIGNAL_RAW" \
        "$SEMGREP_SIGNAL_STDERR" auto "$SEMGREP_SIGNAL_SNAPSHOT" . || rc=$?
assert_eq "143" "$rc" \
    "TERM at the terminal reap boundary is deferred then preserved"
assert_true "$([ ! -e "$SEMGREP_BOUNDARY_UNSAFE_SIGNAL" ] && echo 0 || echo 1)" \
    "terminal reap cancellation never re-enters numeric PGID signalling"
SEMGREP_SIGNAL_RESIDUE=$(find "$SEMGREP_SIGNAL_TMP" -mindepth 1 -print -quit)
assert_true "$([ -z "$SEMGREP_SIGNAL_RESIDUE" ] && echo 0 || echo 1)" \
    "terminal reap cancellation removes private Semgrep control state"
rmdir "$SEMGREP_SIGNAL_SNAPSHOT"
rmdir "$SEMGREP_SIGNAL_TMP"

# ---------------------------------------------------------------------------
# Dispatcher is allowlisted (must not invoke arbitrary shell functions)
# ---------------------------------------------------------------------------
out=$("$GH_PR_ENRICH" --test-call rm -rf / 2>&1 || true)
assert_contains "$out" "not test-callable" "--test-call rejects non-allowlisted names"

out=$("$GH_PR_ENRICH" --test-call 2>&1 || true)
assert_contains "$out" "requires a function name" "--test-call without a function name errors"

suite_end
