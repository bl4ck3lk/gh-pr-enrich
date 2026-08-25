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

# ---------------------------------------------------------------------------
# No duplicated function bodies
# ---------------------------------------------------------------------------
def_count=$(grep -c '^build_analysis_context() {' "$GH_PR_ENRICH" || true)
assert_eq "1" "$def_count" "build_analysis_context is defined exactly once"

legacy_wrapper_count=$(grep -c '^build_claude_context() {' "$GH_PR_ENRICH" || true)
assert_eq "1" "$legacy_wrapper_count" "the legacy Claude builder name has one thin wrapper"

# The inlined copy was identified by this comment; it must not come back.
inline_marker=$(grep -c 'Inlined version of build_claude_context' "$GH_PR_ENRICH" || true)
assert_eq "0" "$inline_marker" "no inlined copy of build_claude_context remains"

# The context document must be assembled in exactly one place. Two writers means
# one of them is a copy that will drift.
writer_count=$(grep -c '> "$output_dir/analysis-context.tmp.json"' "$GH_PR_ENRICH" || true)
assert_eq "1" "$writer_count" "analysis-context.json is written by exactly one code path"

compat_copy_count=$(grep -c 'copy_compatibility_file "$output_dir/analysis-context.json" "$output_dir/claude-context.json"' "$GH_PR_ENRICH" || true)
assert_eq "1" "$compat_copy_count" "the legacy Claude context is only a compatibility alias"

# ---------------------------------------------------------------------------
# Generic test dispatcher replaces the special-cased --test-build-context hook
# ---------------------------------------------------------------------------
assert_eq "0" "$(grep -c -- '--test-build-context' "$GH_PR_ENRICH" || true)" \
    "special-cased --test-build-context hook removed"

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

# ---------------------------------------------------------------------------
# Dispatcher is allowlisted (must not invoke arbitrary shell functions)
# ---------------------------------------------------------------------------
out=$("$GH_PR_ENRICH" --test-call rm -rf / 2>&1 || true)
assert_contains "$out" "not test-callable" "--test-call rejects non-allowlisted names"

out=$("$GH_PR_ENRICH" --test-call 2>&1 || true)
assert_contains "$out" "requires a function name" "--test-call without a function name errors"

suite_end
