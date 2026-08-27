#!/bin/bash
# Focused behavioral coverage for the report command/watchdog ownership protocol.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GH_PR_ENRICH="$PROJECT_DIR/gh-pr-enrich"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output/report-watchdog"
STUB_DIR="$TEST_OUTPUT_DIR/stubs"
BACKGROUND_PID=""

# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

cleanup() {
    # Never signal numeric PIDs read from completed fixtures: by EXIT they may
    # have been reaped and reused. Each case owns and waits its live child before
    # clearing BACKGROUND_PID; CI job teardown contains an interrupted case.
    rm -rf "$TEST_OUTPUT_DIR"
}
trap cleanup EXIT
cleanup
mkdir -p "$STUB_DIR"

# Keep the deadline semantics and grace-period ordering while making the focused
# fixtures finish in well under a second.
cat > "$STUB_DIR/sleep" << 'STUB'
#!/bin/bash
case "${1:-}" in
    0.01|0.02) exec /bin/sleep 0.001 ;;
    0.2) exec /bin/sleep 0.01 ;;
    1) exec /bin/sleep 0.15 ;;
esac
exec /bin/sleep "$@"
STUB
chmod +x "$STUB_DIR/sleep"

DEBUG_ENV="$TEST_OUTPUT_DIR/debug-env"
cat > "$DEBUG_ENV" << 'STUB'
__gh_pr_enrich_report_debug() {
    if [ "$BASH_COMMAND" = 'command_pid=$!' ] && \
       [ -n "${REPORT_TEST_SUPERVISOR_PID_FILE:-}" ]; then
        printf '%s\n' "$!" > "$REPORT_TEST_SUPERVISOR_PID_FILE"
    elif [ "$BASH_COMMAND" = 'REPORT_RUN_WATCHDOG_PID=$!' ] && \
         [ -n "${REPORT_TEST_WATCHDOG_PID_FILE:-}" ]; then
        printf '%s\n' "$!" > "$REPORT_TEST_WATCHDOG_PID_FILE"
    fi
}
set -T
trap '__gh_pr_enrich_report_debug' DEBUG
unset BASH_ENV
STUB

pid_is_gone() {
    local pid="$1" attempt=0 state=""
    [ -n "$pid" ] || return 1
    while [ "$attempt" -lt 100 ]; do
        kill -0 "$pid" 2>/dev/null || return 0
        state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
        case "$state" in
            ""|Z*) return 0 ;;
        esac
        /bin/sleep 0.01
        attempt=$((attempt + 1))
    done
    return 1
}

pid_file_value() {
    local pid_file="$1" attempt=0
    while [ ! -s "$pid_file" ] && [ "$attempt" -lt 300 ]; do
        /bin/sleep 0.01
        attempt=$((attempt + 1))
    done
    cat "$pid_file" 2>/dev/null || echo ""
}

suite_start "gh-pr-enrich report watchdog suite"

# A normal nonzero command must keep its status, and both manager processes must
# be gone before the owner returns.
FAST_DIR="$TEST_OUTPUT_DIR/fast"
FAST_SUPERVISOR_PID_FILE="$TEST_OUTPUT_DIR/fast-supervisor.pid"
FAST_WATCHDOG_PID_FILE="$TEST_OUTPUT_DIR/fast-watchdog.pid"
mkdir -p "$FAST_DIR"
rc=0
env PATH="$STUB_DIR:$PATH" TMPDIR="$FAST_DIR" BASH_ENV="$DEBUG_ENV" \
    REPORT_TEST_SUPERVISOR_PID_FILE="$FAST_SUPERVISOR_PID_FILE" \
    REPORT_TEST_WATCHDOG_PID_FILE="$FAST_WATCHDOG_PID_FILE" \
    "$GH_PR_ENRICH" --test-call exercise_report_run_watchdog fast \
    >/dev/null 2>&1 || rc=$?
FAST_SUPERVISOR_PID=$(pid_file_value "$FAST_SUPERVISOR_PID_FILE")
FAST_WATCHDOG_PID=$(pid_file_value "$FAST_WATCHDOG_PID_FILE")
assert_eq "7" "$rc" "fast report commands preserve their exit status"
assert_true "$([ -n "$FAST_SUPERVISOR_PID" ] && \
    pid_is_gone "$FAST_SUPERVISOR_PID" && echo 0 || echo 1)" \
    "fast report commands reap their supervisor before returning"
assert_true "$([ -n "$FAST_WATCHDOG_PID" ] && \
    pid_is_gone "$FAST_WATCHDOG_PID" && echo 0 || echo 1)" \
    "fast report commands reap their watchdog before returning"

# The real command cannot launch unless the parent proves the supervisor owns
# an isolated process group.
UNOWNED_DIR="$TEST_OUTPUT_DIR/unowned"
UNOWNED_SUPERVISOR_PID_FILE="$TEST_OUTPUT_DIR/unowned-supervisor.pid"
UNOWNED_START_MARKER="$TEST_OUTPUT_DIR/unowned-command-started"
mkdir -p "$UNOWNED_DIR"
rc=0
env PATH="$STUB_DIR:$PATH" TMPDIR="$UNOWNED_DIR" BASH_ENV="$DEBUG_ENV" \
    GH_PR_ENRICH_TEST_FORCE_UNOWNED_REPORT_GROUP=true \
    REPORT_TEST_SUPERVISOR_PID_FILE="$UNOWNED_SUPERVISOR_PID_FILE" \
    "$GH_PR_ENRICH" --test-call exercise_report_run_watchdog \
        start-marker "$UNOWNED_START_MARKER" >/dev/null 2>&1 || rc=$?
UNOWNED_SUPERVISOR_PID=$(pid_file_value "$UNOWNED_SUPERVISOR_PID_FILE")
assert_eq "125" "$rc" "unowned report process groups fail closed"
assert_true "$([ ! -e "$UNOWNED_START_MARKER" ] && echo 0 || echo 1)" \
    "an unowned process group cannot launch the real command"
assert_true "$([ -n "$UNOWNED_SUPERVISOR_PID" ] && \
    pid_is_gone "$UNOWNED_SUPERVISOR_PID" && echo 0 || echo 1)" \
    "a rejected supervisor is reaped without signalling its saved PID"

# A TERM-responsive command exits during the grace period. The supervisor must
# still anchor the process group until the watchdog sends KILL and returns 124.
TIMEOUT_DIR="$TEST_OUTPUT_DIR/timeout"
TIMEOUT_SUPERVISOR_PID_FILE="$TEST_OUTPUT_DIR/timeout-supervisor.pid"
TIMEOUT_WATCHDOG_PID_FILE="$TEST_OUTPUT_DIR/timeout-watchdog.pid"
TIMEOUT_CHILD_PID_FILE="$TEST_OUTPUT_DIR/timeout-child.pid"
TIMEOUT_DESCENDANT_PID_FILE="$TEST_OUTPUT_DIR/timeout-descendant.pid"
TIMEOUT_TERM_MARKER="$TEST_OUTPUT_DIR/timeout-term"
mkdir -p "$TIMEOUT_DIR"
env PATH="$STUB_DIR:$PATH" TMPDIR="$TIMEOUT_DIR" BASH_ENV="$DEBUG_ENV" \
    GH_PR_ENRICH_GITHUB_TIMEOUT=1 \
    REPORT_TEST_SUPERVISOR_PID_FILE="$TIMEOUT_SUPERVISOR_PID_FILE" \
    REPORT_TEST_WATCHDOG_PID_FILE="$TIMEOUT_WATCHDOG_PID_FILE" \
    "$GH_PR_ENRICH" --test-call exercise_report_run_watchdog timeout \
        "$TIMEOUT_CHILD_PID_FILE" "$TIMEOUT_DESCENDANT_PID_FILE" \
        "$TIMEOUT_TERM_MARKER" >/dev/null 2>&1 &
BACKGROUND_PID=$!
TIMEOUT_SUPERVISOR_PID=$(pid_file_value "$TIMEOUT_SUPERVISOR_PID_FILE")
for (( attempt=0; attempt < 300; attempt++ )); do
    [ -e "$TIMEOUT_TERM_MARKER" ] && break
    /bin/sleep 0.01
done
group_alive=false
if [ -n "$TIMEOUT_SUPERVISOR_PID" ] && \
   kill -0 -- "-$TIMEOUT_SUPERVISOR_PID" 2>/dev/null; then
    group_alive=true
fi
rc=0
wait "$BACKGROUND_PID" || rc=$?
BACKGROUND_PID=""
TIMEOUT_WATCHDOG_PID=$(pid_file_value "$TIMEOUT_WATCHDOG_PID_FILE")
TIMEOUT_CHILD_PID=$(pid_file_value "$TIMEOUT_CHILD_PID_FILE")
TIMEOUT_DESCENDANT_PID=$(pid_file_value "$TIMEOUT_DESCENDANT_PID_FILE")
assert_true "$([ -e "$TIMEOUT_TERM_MARKER" ] && \
    [ "$group_alive" = true ] && echo 0 || echo 1)" \
    "the supervisor anchors a TERM-responsive command group through KILL grace"
assert_eq "124" "$rc" "deadline expiry returns the managed timeout status"
for reaped_case in \
        "supervisor:$TIMEOUT_SUPERVISOR_PID" \
        "watchdog:$TIMEOUT_WATCHDOG_PID" \
        "command:$TIMEOUT_CHILD_PID" \
        "descendant:$TIMEOUT_DESCENDANT_PID"; do
    reaped_name=${reaped_case%%:*}
    reaped_pid=${reaped_case#*:}
    assert_true "$([ -n "$reaped_pid" ] && pid_is_gone "$reaped_pid" && \
        echo 0 || echo 1)" \
        "timeout cleanup reaps the $reaped_name process"
done

# Cancellation is requested through the watcher after command publication. It
# must own TERM/KILL and exit before the owner reaps the supervisor PGID anchor.
CANCEL_DIR="$TEST_OUTPUT_DIR/cancel"
CANCEL_SUPERVISOR_PID_FILE="$TEST_OUTPUT_DIR/cancel-supervisor.pid"
CANCEL_WATCHDOG_PID_FILE="$TEST_OUTPUT_DIR/cancel-watchdog.pid"
CANCEL_CHILD_PID_FILE="$TEST_OUTPUT_DIR/cancel-child.pid"
CANCEL_DESCENDANT_PID_FILE="$TEST_OUTPUT_DIR/cancel-descendant.pid"
CANCEL_TERM_MARKER="$TEST_OUTPUT_DIR/cancel-term"
mkdir -p "$CANCEL_DIR"
env PATH="$STUB_DIR:$PATH" TMPDIR="$CANCEL_DIR" BASH_ENV="$DEBUG_ENV" \
    GH_PR_ENRICH_GITHUB_TIMEOUT=30 \
    REPORT_TEST_SUPERVISOR_PID_FILE="$CANCEL_SUPERVISOR_PID_FILE" \
    REPORT_TEST_WATCHDOG_PID_FILE="$CANCEL_WATCHDOG_PID_FILE" \
    "$GH_PR_ENRICH" --test-call exercise_report_run_watchdog cancel \
        "$CANCEL_CHILD_PID_FILE" "$CANCEL_DESCENDANT_PID_FILE" \
        "$CANCEL_TERM_MARKER" >/dev/null 2>&1 &
BACKGROUND_PID=$!
CANCEL_DESCENDANT_PID=$(pid_file_value "$CANCEL_DESCENDANT_PID_FILE")
if [ -n "$CANCEL_DESCENDANT_PID" ] && \
        kill -0 "$BACKGROUND_PID" 2>/dev/null; then
    assert_true 0 "managed cancellation waits for the command descendant"
    kill -TERM "$BACKGROUND_PID" 2>/dev/null || true
else
    assert_true 1 "managed cancellation waits for the command descendant"
fi
rc=0
wait "$BACKGROUND_PID" || rc=$?
BACKGROUND_PID=""
CANCEL_SUPERVISOR_PID=$(pid_file_value "$CANCEL_SUPERVISOR_PID_FILE")
CANCEL_WATCHDOG_PID=$(pid_file_value "$CANCEL_WATCHDOG_PID_FILE")
CANCEL_CHILD_PID=$(pid_file_value "$CANCEL_CHILD_PID_FILE")
assert_eq "143" "$rc" "managed cancellation preserves conventional TERM status"
assert_true "$([ -e "$CANCEL_TERM_MARKER" ] && echo 0 || echo 1)" \
    "managed cancellation sends TERM through the command watchdog"
for reaped_case in \
        "supervisor:$CANCEL_SUPERVISOR_PID" \
        "watchdog:$CANCEL_WATCHDOG_PID" \
        "command:$CANCEL_CHILD_PID" \
        "descendant:$CANCEL_DESCENDANT_PID"; do
    reaped_name=${reaped_case%%:*}
    reaped_pid=${reaped_case#*:}
    assert_true "$([ -n "$reaped_pid" ] && pid_is_gone "$reaped_pid" && \
        echo 0 || echo 1)" \
        "managed cancellation reaps the $reaped_name process"
done

suite_end
