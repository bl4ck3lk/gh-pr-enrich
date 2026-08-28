#!/bin/bash
# Focused coverage for the parent-owned capture supervisor/watchdog handoff.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GH_PR_ENRICH="$PROJECT_DIR/gh-pr-enrich"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output/parent-capture"
CAPTURE_TMP="$TEST_OUTPUT_DIR/tmp"

# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

cleanup() {
    [ -z "${CAPTURE_CLI_PID:-}" ] || \
        kill -KILL "$CAPTURE_CLI_PID" 2>/dev/null || true
    rm -rf "$TEST_OUTPUT_DIR"
}
trap cleanup EXIT
cleanup
mkdir -p "$CAPTURE_TMP"

suite_start "gh-pr-enrich parent capture suite"

NORMAL_OUTPUT="$TEST_OUTPUT_DIR/normal-output"
TMPDIR="$CAPTURE_TMP" "$GH_PR_ENRICH" --test-call \
    run_parent_managed_capture "$NORMAL_OUTPUT" bash -c 'printf complete'
assert_eq "complete" "$(cat "$NORMAL_OUTPUT")" \
    "a completed capture releases and reaps its supervisor"

SIGNAL_OUTPUT="$TEST_OUTPUT_DIR/signal-output"
SIGNAL_READY="$TEST_OUTPUT_DIR/signal-ready"
SUPERVISOR_PID_FILE="$TEST_OUTPUT_DIR/supervisor-pid"
env TMPDIR="$CAPTURE_TMP" CAPTURE_SIGNAL_READY="$SIGNAL_READY" \
    GH_PR_ENRICH_DEBUG_PARENT_CAPTURE_PID_FILE="$SUPERVISOR_PID_FILE" \
    "$GH_PR_ENRICH" --test-call run_parent_managed_capture "$SIGNAL_OUTPUT" \
        bash -c 'trap "exit 143" TERM; : > "$CAPTURE_SIGNAL_READY"; while :; do sleep 0.05; done' \
        >/dev/null 2>&1 &
CAPTURE_CLI_PID=$!
attempt=0
while [ ! -e "$SIGNAL_READY" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.01
    attempt=$((attempt + 1))
done
kill -TERM "$CAPTURE_CLI_PID" 2>/dev/null || true
rc=0
wait "$CAPTURE_CLI_PID" || rc=$?
CAPTURE_CLI_PID=""
SUPERVISOR_PID=$(tail -1 "$SUPERVISOR_PID_FILE" 2>/dev/null || echo "")
assert_true "$([ -e "$SIGNAL_READY" ] && echo 0 || echo 1)" \
    "the cancellation fixture reaches the managed capture command"
assert_eq "143" "$rc" \
    "TERM preserves the conventional parent-capture status"
assert_true "$([ -n "$SUPERVISOR_PID" ] && \
    ! kill -0 "$SUPERVISOR_PID" 2>/dev/null && echo 0 || echo 1)" \
    "cancellation reaps the capture supervisor after watchdog exit"
assert_true "$([ ! -e "$SIGNAL_OUTPUT" ] && echo 0 || echo 1)" \
    "cancellation removes partial captured output"
CAPTURE_RESIDUE=$(find "$CAPTURE_TMP" \
    -name 'gh-pr-enrich-parent-capture.*' -print -quit)
assert_true "$([ -z "$CAPTURE_RESIDUE" ] && echo 0 || echo 1)" \
    "capture handoff removes private control state"

NESTED_OUTPUT="$TEST_OUTPUT_DIR/nested-output"
NESTED_CHILD_PID_FILE="$TEST_OUTPUT_DIR/nested-child-pid"
NESTED_DESCENDANT_PID_FILE="$TEST_OUTPUT_DIR/nested-descendant-pid"
NESTED_TERM_MARKER="$TEST_OUTPUT_DIR/nested-term"
env TMPDIR="$CAPTURE_TMP" GH_PR_ENRICH_GITHUB_TIMEOUT=30 \
    "$GH_PR_ENRICH" --test-call exercise_parent_capture_nested_watchdog \
        "$NESTED_OUTPUT" "$NESTED_CHILD_PID_FILE" \
        "$NESTED_DESCENDANT_PID_FILE" "$NESTED_TERM_MARKER" \
        >/dev/null 2>&1 &
CAPTURE_CLI_PID=$!
attempt=0
while [ ! -s "$NESTED_DESCENDANT_PID_FILE" ] && [ "$attempt" -lt 200 ]; do
    sleep 0.01
    attempt=$((attempt + 1))
done
kill -TERM "$CAPTURE_CLI_PID" 2>/dev/null || true
rc=0
wait "$CAPTURE_CLI_PID" 2>/dev/null || rc=$?
CAPTURE_CLI_PID=""
NESTED_CHILD_PID=$(cat "$NESTED_CHILD_PID_FILE" 2>/dev/null || echo "")
NESTED_DESCENDANT_PID=$(cat \
    "$NESTED_DESCENDANT_PID_FILE" 2>/dev/null || echo "")
assert_eq "143" "$rc" \
    "outer cancellation preserves status through the nested watchdog"
assert_true "$([ -e "$NESTED_TERM_MARKER" ] && echo 0 || echo 1)" \
    "the nested watchdog remains the sole TERM/KILL owner"
assert_true "$([ -n "$NESTED_CHILD_PID" ] && \
    ! kill -0 "$NESTED_CHILD_PID" 2>/dev/null && echo 0 || echo 1)" \
    "nested watchdog cancellation reaps its command"
assert_true "$([ -n "$NESTED_DESCENDANT_PID" ] && \
    ! kill -0 "$NESTED_DESCENDANT_PID" 2>/dev/null && echo 0 || echo 1)" \
    "nested watchdog cancellation reaps the command descendant"

OWNER_DEATH_OUTPUT="$TEST_OUTPUT_DIR/owner-death-output"
OWNER_DEATH_READY="$TEST_OUTPUT_DIR/owner-death-ready"
OWNER_DEATH_GATE="$TEST_OUTPUT_DIR/owner-death-gate"
OWNER_DEATH_SUPERVISOR_PID_FILE="$TEST_OUTPUT_DIR/owner-death-supervisor-pid"
env TMPDIR="$CAPTURE_TMP" \
    GH_PR_ENRICH_DEBUG_PARENT_CAPTURE_PID_FILE="$OWNER_DEATH_SUPERVISOR_PID_FILE" \
    GH_PR_ENRICH_TEST_PARENT_CAPTURE_RELEASE_READY="$OWNER_DEATH_READY" \
    GH_PR_ENRICH_TEST_PARENT_CAPTURE_RELEASE_GATE="$OWNER_DEATH_GATE" \
    "$GH_PR_ENRICH" --test-call run_parent_managed_capture \
        "$OWNER_DEATH_OUTPUT" bash -c 'printf complete' >/dev/null 2>&1 &
CAPTURE_CLI_PID=$!
attempt=0
while [ ! -e "$OWNER_DEATH_READY" ] && [ "$attempt" -lt 100 ]; do
    sleep 0.01
    attempt=$((attempt + 1))
done
OWNER_DEATH_SUPERVISOR_PID=$(tail -1 \
    "$OWNER_DEATH_SUPERVISOR_PID_FILE" 2>/dev/null || echo "")
kill -KILL "$CAPTURE_CLI_PID" 2>/dev/null || true
rc=0
wait "$CAPTURE_CLI_PID" 2>/dev/null || rc=$?
CAPTURE_CLI_PID=""
attempt=0
while [ -n "$OWNER_DEATH_SUPERVISOR_PID" ] && \
      kill -0 "$OWNER_DEATH_SUPERVISOR_PID" 2>/dev/null && \
      [ "$attempt" -lt 100 ]; do
    sleep 0.01
    attempt=$((attempt + 1))
done
assert_true "$([ -e "$OWNER_DEATH_READY" ] && echo 0 || echo 1)" \
    "the owner-death fixture reaches the completed-supervisor handoff"
assert_eq "137" "$rc" "the owner-death fixture terminates only the owner"
assert_true "$([ -n "$OWNER_DEATH_SUPERVISOR_PID" ] && \
    ! kill -0 "$OWNER_DEATH_SUPERVISOR_PID" 2>/dev/null && echo 0 || echo 1)" \
    "owner-lease EOF releases an otherwise orphaned completed supervisor"
CAPTURE_RESIDUE=$(find "$CAPTURE_TMP" \
    -name 'gh-pr-enrich-parent-capture.*' -print -quit)
assert_true "$([ -z "$CAPTURE_RESIDUE" ] && echo 0 || echo 1)" \
    "owner-lease EOF removes private capture control state"

suite_end
