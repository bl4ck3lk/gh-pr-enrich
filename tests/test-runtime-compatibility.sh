#!/bin/bash
# Cross-runtime contract: one canonical skill installs into Claude and Codex,
# context preparation works without an external analyzer, and private PR data is
# not disclosed to Claude without a separate explicit authorization flag.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GH_PR_ENRICH="$PROJECT_DIR/gh-pr-enrich"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output/runtime-compatibility"
STUB_DIR="$TEST_OUTPUT_DIR/stubs"
TMP_ALIAS_OUTPUT="/tmp/gh-pr-enrich-runtime-$$"
RUNTIME_BACKGROUND_PID=""
COLLECTION_LOCK_RELEASE=""
COLLECTION_ACQUIRE_RELEASE=""
COLLECTION_SIGNAL_RM_RELEASE=""
LINKED_CONCURRENT_RELEASE=""
CHILD_START_PID_FILE=""

# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

cleanup() {
    if [ -n "$RUNTIME_BACKGROUND_PID" ]; then
        [ -z "$COLLECTION_LOCK_RELEASE" ] || \
            : > "$COLLECTION_LOCK_RELEASE" 2>/dev/null || true
        [ -z "$COLLECTION_ACQUIRE_RELEASE" ] || \
            : > "$COLLECTION_ACQUIRE_RELEASE" 2>/dev/null || true
        [ -z "$COLLECTION_SIGNAL_RM_RELEASE" ] || \
            : > "$COLLECTION_SIGNAL_RM_RELEASE" 2>/dev/null || true
        [ -z "$LINKED_CONCURRENT_RELEASE" ] || \
            : > "$LINKED_CONCURRENT_RELEASE" 2>/dev/null || true
        kill "$RUNTIME_BACKGROUND_PID" 2>/dev/null || true
        for _cleanup_attempt in $(seq 1 40); do
            kill -0 "$RUNTIME_BACKGROUND_PID" 2>/dev/null || break
            sleep 0.05
        done
        if kill -0 "$RUNTIME_BACKGROUND_PID" 2>/dev/null; then
            kill -KILL "$RUNTIME_BACKGROUND_PID" 2>/dev/null || true
        fi
        wait "$RUNTIME_BACKGROUND_PID" 2>/dev/null || true
        RUNTIME_BACKGROUND_PID=""
    fi
    if [ -n "$CHILD_START_PID_FILE" ] && [ -f "$CHILD_START_PID_FILE" ]; then
        cleanup_child_pid=$(cat "$CHILD_START_PID_FILE" 2>/dev/null || echo "")
        if [ -n "$cleanup_child_pid" ] && \
           kill -0 "$cleanup_child_pid" 2>/dev/null; then
            kill -KILL "$cleanup_child_pid" 2>/dev/null || true
        fi
    fi
    rm -rf "$TEST_OUTPUT_DIR" "$TMP_ALIAS_OUTPUT"
}
trap cleanup EXIT
cleanup
mkdir -p "$STUB_DIR"

suite_start "gh pr-enrich runtime compatibility suite"

# GNU stat accepts -c while BSD stat accepts -f. Probe GNU first and never
# mistake a failed probe's diagnostic text for a permission mode.
GNU_STAT_STUBS="$TEST_OUTPUT_DIR/gnu-stat-stubs"
GNU_STAT_LOG="$TEST_OUTPUT_DIR/gnu-stat.log"
mkdir -p "$GNU_STAT_STUBS"
cat > "$GNU_STAT_STUBS/stat" << 'STUB'
#!/bin/bash
printf '%s\n' "$1" >> "$GNU_STAT_LOG"
case "$1" in
    -c) echo 640; exit 0 ;;
    -f) echo 777; exit 0 ;;
esac
exit 1
STUB
chmod +x "$GNU_STAT_STUBS/stat"
MODE_FIXTURE="$TEST_OUTPUT_DIR/mode-fixture"
: > "$MODE_FIXTURE"
GNU_MODE=$(env GNU_STAT_LOG="$GNU_STAT_LOG" PATH="$GNU_STAT_STUBS:$PATH" \
    "$GH_PR_ENRICH" --test-call workspace_file_mode "$MODE_FIXTURE")
assert_eq "640" "$GNU_MODE" "GNU stat mode probing uses -c output"
assert_eq "-c" "$(cat "$GNU_STAT_LOG")" \
    "a valid GNU mode does not fall through to the BSD probe"

CODEX_ADAPTER="$PROJECT_DIR/.agents/skills/gh-pr-enrich/SKILL.md"
CANONICAL_SKILL="$PROJECT_DIR/.claude/skills/gh-pr-enrich/SKILL.md"
assert_contains "$(cat "$CODEX_ADAPTER")" "../../../.claude/skills/gh-pr-enrich/SKILL.md" \
    "the project-local Codex adapter points to the canonical skill"
assert_contains "$(cat "$CODEX_ADAPTER")" "native subagents" \
    "the Codex adapter selects current-session native subagents"
ADAPTER_LINES=$(wc -l < "$CODEX_ADAPTER" | tr -d ' ')
assert_true "$([ "$ADAPTER_LINES" -lt 40 ] && echo 0 || echo 1)" \
    "the Codex adapter cannot drift into a second full skill copy"
assert_contains "$(cat "$CANONICAL_SKILL")" "Review mode is the default" \
    "the canonical skill keeps review and remediation authority separate"
assert_contains "$(cat "$CANONICAL_SKILL")" "hybrid-analysis.json" \
    "the canonical skill defines a truthful hybrid artifact"
assert_contains "$(cat "$CANONICAL_SKILL")" "--allow-external" \
    "the canonical skill enforces the external disclosure gate"
assert_contains "$(cat "$CANONICAL_SKILL")" \
    'materialize-analysis-snapshot "$REPORT_DIR"' \
    "native orchestrators materialize the verified immutable workspace"
assert_contains "$(cat "$CANONICAL_SKILL")" \
    'MUST read code only under `SNAPSHOT_PATH`' \
    "every native root and subagent is confined to the materialized path"
assert_contains "$(cat "$CANONICAL_SKILL")" \
    'cleanup-analysis-snapshot "$SNAPSHOT_PATH"' \
    "the native workflow requires explicit snapshot cleanup"
assert_contains "$(cat "$CANONICAL_SKILL")" \
    '`_metadata.workspace_fingerprint`' \
    "native artifacts bind the materialized workspace fingerprint"

# ---------------------------------------------------------------------------
# Skill installation
# ---------------------------------------------------------------------------
TEST_HOME="$TEST_OUTPUT_DIR/home"
mkdir -p "$TEST_HOME"

HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill >/dev/null

CLAUDE_SKILL="$TEST_HOME/.claude/skills/gh-pr-enrich"
CODEX_SKILL="$TEST_HOME/.codex/skills/gh-pr-enrich"

assert_true "$([ -L "$CLAUDE_SKILL" ] && echo 0 || echo 1)" \
    "the default installer registers the Claude skill"
assert_true "$([ -L "$CODEX_SKILL" ] && echo 0 || echo 1)" \
    "the default installer registers the Codex skill"
assert_eq "$(cd "$CLAUDE_SKILL" && pwd -P)" "$(cd "$CODEX_SKILL" && pwd -P)" \
    "both runtimes use one canonical skill source"

HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill >/dev/null
assert_true "$([ ! -e "$CLAUDE_SKILL" ] && echo 0 || echo 1)" \
    "the uninstaller removes the Claude registration"
assert_true "$([ ! -e "$CODEX_SKILL" ] && echo 0 || echo 1)" \
    "the uninstaller removes the Codex registration"

# Default uninstall preflights both registrations before removing either. An
# operator-owned Claude path must not leave the Codex half uninstalled.
HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill >/dev/null
rm "$CLAUDE_SKILL"
echo "operator-owned" > "$CLAUDE_SKILL"
rc=0
HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "an unsafe Claude target fails the default uninstall preflight"
assert_true "$([ -L "$CODEX_SKILL" ] && echo 0 || echo 1)" \
    "a failed two-runtime uninstall preserves the Codex registration"
assert_eq "operator-owned" "$(cat "$CLAUDE_SKILL")" \
    "a failed two-runtime uninstall preserves the unsafe Claude target"
rm "$CLAUDE_SKILL"
HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill --runtime codex >/dev/null

# A failure while removing the second runtime rolls the first registration back
# from its captured payload. The rollback uses ln's no-overwrite behavior, so a
# concurrent replacement is never clobbered.
HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill >/dev/null
CODEX_PAYLOAD_BEFORE=$(readlink "$CODEX_SKILL")
CLAUDE_PAYLOAD_BEFORE=$(readlink "$CLAUDE_SKILL")
FAIL_RM_STUBS="$TEST_OUTPUT_DIR/failing-uninstall-rm"
mkdir -p "$FAIL_RM_STUBS"
cat > "$FAIL_RM_STUBS/rm" << 'STUB'
#!/bin/bash
if [ "$1" = "$FAIL_RM_TARGET" ]; then
    exit 73
fi
exec /bin/rm "$@"
STUB
chmod +x "$FAIL_RM_STUBS/rm"
rc=0
env HOME="$TEST_HOME" FAIL_RM_TARGET="$CLAUDE_SKILL" \
    PATH="$FAIL_RM_STUBS:$PATH" \
    "$GH_PR_ENRICH" uninstall-skill >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a second-runtime removal failure fails the transactional uninstall"
assert_eq "$CODEX_PAYLOAD_BEFORE" "$(readlink "$CODEX_SKILL")" \
    "a second-runtime removal failure restores the Codex symlink payload"
assert_eq "$CLAUDE_PAYLOAD_BEFORE" "$(readlink "$CLAUDE_SKILL")" \
    "a failed Claude removal preserves its captured symlink payload"
HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill >/dev/null

# Uninstall has historically removed any symlink registration, including stale
# and broken links. Atomic preflight must not tighten that public behavior.
mkdir -p "$TEST_HOME/.claude/skills"
ln -s "$TEST_OUTPUT_DIR/nonexistent-skill-source" "$CLAUDE_SKILL"
HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill --runtime claude >/dev/null
assert_true "$([ ! -L "$CLAUDE_SKILL" ] && echo 0 || echo 1)" \
    "uninstall still removes a broken symlink registration"

HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill --runtime codex >/dev/null
assert_true "$([ -L "$CODEX_SKILL" ] && echo 0 || echo 1)" \
    "--runtime codex installs only the Codex registration"
assert_true "$([ ! -e "$CLAUDE_SKILL" ] && echo 0 || echo 1)" \
    "--runtime codex does not install the Claude registration"
HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill --runtime codex >/dev/null

# A collision in the second runtime is detected before the first registration is
# changed, so the default two-runtime install is transactional.
mkdir -p "$TEST_HOME/.claude/skills"
echo "operator-owned" > "$CLAUDE_SKILL"
rc=0
HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a conflicting Claude target fails the two-runtime install"
assert_true "$([ ! -e "$CODEX_SKILL" ] && echo 0 || echo 1)" \
    "a failed two-runtime install leaves Codex unregistered"
assert_eq "operator-owned" "$(cat "$CLAUDE_SKILL")" \
    "a failed two-runtime install preserves the conflicting target"
rm "$CLAUDE_SKILL"

# ---------------------------------------------------------------------------
# End-to-end stubs
# ---------------------------------------------------------------------------
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
    "pr view")
        if [ -n "${MUTATE_ANALYSIS_SOURCE:-}" ] && [ -f "$MUTATE_ANALYSIS_SOURCE" ]; then
            jq '.task_list[0].task = "mutated after selector freeze"' \
                "$MUTATE_ANALYSIS_SOURCE" > "$MUTATE_ANALYSIS_SOURCE.tmp"
            mv "$MUTATE_ANALYSIS_SOURCE.tmp" "$MUTATE_ANALYSIS_SOURCE"
        fi
        if [ -n "${MUTATE_ANALYSIS_CONTEXT:-}" ] && \
           [ -f "${REPLACEMENT_ANALYSIS_CONTEXT:-}" ]; then
            cp "$REPLACEMENT_ANALYSIS_CONTEXT" "$MUTATE_ANALYSIS_CONTEXT"
        fi
        cat << JSON
{"number":1,"title":"t","body":"b","author":{"login":"u"},"state":"OPEN",
 "url":"https://github.com/o/r/pull/1","createdAt":"2026-01-01T00:00:00Z",
 "updatedAt":"2026-01-01T00:00:00Z","mergeable":"MERGEABLE","isDraft":false,
 "additions":1,"deletions":0,"changedFiles":1,"headRefOid":"${PR_HEAD_OID:-abc123}",
 "files":[{"path":"gh-pr-enrich","additions":1,"deletions":0}],"commits":[],
 "labels":[],"assignees":[],"reviews":[]}
JSON
        exit 0
        ;;
    "pr checks") echo '[]'; exit 0 ;;
    "pr diff")
        printf 'diff --git a/a.js b/a.js\n--- a/a.js\n+++ b/a.js\n@@ -0,0 +1 @@\n+const x = 1;\n'
        exit 0
        ;;
esac
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    case "$*" in
        *closingIssuesReferences*) echo '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}' ;;
        *) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PRRT_open","isResolved":false,"isOutdated":false,"path":"a.js","line":1,"comments":{"nodes":[{"id":"c","databaseId":1,"body":"check this","author":{"login":"rev"},"createdAt":"2026-01-01T00:00:00Z","url":"https://github.com/o/r/pull/1#discussion_r1"}]}}]}}}}}' ;;
    esac
    exit 0
fi
if [ "$1" = "api" ]; then echo '[]'; exit 0; fi
exit 0
STUB
chmod +x "$STUB_DIR/gh"

cat > "$STUB_DIR/claude" << 'STUB'
#!/bin/bash
echo invoked >> "$CLAUDE_INVOKED_LOG"
cat > /dev/null
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

cat > "$STUB_DIR/semgrep" << 'STUB'
#!/bin/bash
cat << 'JSON'
{"results":[{"check_id":"shell.security.example","path":"gh-pr-enrich",
 "start":{"line":1},"extra":{"severity":"WARNING","message":"fixture finding","metadata":{}}}],"errors":[]}
JSON
STUB
chmod +x "$STUB_DIR/semgrep"

# Collection and all downstream consumers form one report-directory
# transaction. A second run may resolve repository metadata, but it must not
# reach the first shared PR input write while the original run owns the lock.
COLLECTION_LOCK_STUBS="$TEST_OUTPUT_DIR/collection-lock-stubs"
COLLECTION_LOCK_REPORT="$TEST_OUTPUT_DIR/collection-lock-report"
COLLECTION_LOCK_READY="$TEST_OUTPUT_DIR/collection-lock-ready"
COLLECTION_LOCK_RELEASE="$TEST_OUTPUT_DIR/collection-lock-release"
COLLECTION_LOCK_PR_VIEWS="$TEST_OUTPUT_DIR/collection-lock-pr-views"
COLLECTION_LOCK_FIRST_OUT="$TEST_OUTPUT_DIR/collection-lock-first.out"
mkdir -p "$COLLECTION_LOCK_STUBS"
cat > "$COLLECTION_LOCK_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr view" ]; then
    printf 'view\n' >> "$COLLECTION_LOCK_PR_VIEWS"
    if [ ! -e "$COLLECTION_LOCK_READY" ]; then
        : > "$COLLECTION_LOCK_READY"
        while [ ! -e "$COLLECTION_LOCK_RELEASE" ]; do
            sleep 0.05
        done
    fi
fi
exec "$COLLECTION_LOCK_BASE_GH" "$@"
STUB
chmod +x "$COLLECTION_LOCK_STUBS/gh"
env PATH="$COLLECTION_LOCK_STUBS:$STUB_DIR:$PATH" \
    COLLECTION_LOCK_BASE_GH="$STUB_DIR/gh" \
    COLLECTION_LOCK_READY="$COLLECTION_LOCK_READY" \
    COLLECTION_LOCK_RELEASE="$COLLECTION_LOCK_RELEASE" \
    COLLECTION_LOCK_PR_VIEWS="$COLLECTION_LOCK_PR_VIEWS" \
    "$GH_PR_ENRICH" 1 --prepare-analysis --diff \
    --output-dir "$COLLECTION_LOCK_REPORT" \
    > "$COLLECTION_LOCK_FIRST_OUT" 2>&1 &
RUNTIME_BACKGROUND_PID=$!
for _ in $(seq 1 200); do
    [ ! -e "$COLLECTION_LOCK_READY" ] || break
    sleep 0.05
done
assert_true "$([ -e "$COLLECTION_LOCK_READY" ] && echo 0 || echo 1)" \
    "the first report run reaches collection while holding its lifecycle lock"
rc=0
COLLECTION_LOCK_SECOND_OUT=$(env PATH="$COLLECTION_LOCK_STUBS:$STUB_DIR:$PATH" \
    COLLECTION_LOCK_BASE_GH="$STUB_DIR/gh" \
    COLLECTION_LOCK_READY="$COLLECTION_LOCK_READY" \
    COLLECTION_LOCK_RELEASE="$COLLECTION_LOCK_RELEASE" \
    COLLECTION_LOCK_PR_VIEWS="$COLLECTION_LOCK_PR_VIEWS" \
    "$GH_PR_ENRICH" 1 --prepare-analysis --diff \
    --output-dir "$COLLECTION_LOCK_REPORT" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a concurrent run cannot overwrite another run's shared report inputs"
assert_contains "$COLLECTION_LOCK_SECOND_OUT" "input collection is already active" \
    "a concurrent run identifies the protected collection lifecycle"
assert_eq "1" "$(wc -l < "$COLLECTION_LOCK_PR_VIEWS" | tr -d ' ')" \
    "the rejected run performs no PR input fetches"
: > "$COLLECTION_LOCK_RELEASE"
rc=0
wait "$RUNTIME_BACKGROUND_PID" || rc=$?
RUNTIME_BACKGROUND_PID=""
assert_true "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" \
    "the lock owner completes after the concurrent run is rejected"
assert_true "$([ ! -e "$COLLECTION_LOCK_REPORT/.selected-analysis.lock" ] && echo 0 || echo 1)" \
    "the report lifecycle lock is released after successful completion"

COLLECTION_FAILURE_STUBS="$TEST_OUTPUT_DIR/collection-failure-stubs"
COLLECTION_FAILURE_REPORT="$TEST_OUTPUT_DIR/collection-failure-report"
mkdir -p "$COLLECTION_FAILURE_STUBS"
cat > "$COLLECTION_FAILURE_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr view" ]; then
    exit 88
fi
exec "$COLLECTION_FAILURE_BASE_GH" "$@"
STUB
chmod +x "$COLLECTION_FAILURE_STUBS/gh"
rc=0
env PATH="$COLLECTION_FAILURE_STUBS:$STUB_DIR:$PATH" \
    COLLECTION_FAILURE_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" 1 --output-dir "$COLLECTION_FAILURE_REPORT" \
    >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && \
    [ ! -e "$COLLECTION_FAILURE_REPORT/.selected-analysis.lock" ] && echo 0 || echo 1)" \
    "an input-fetch failure releases the whole-run report lock"
env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" 1 \
    --output-dir "$COLLECTION_FAILURE_REPORT" >/dev/null 2>&1
assert_true "$([ -f "$COLLECTION_FAILURE_REPORT/pr-summary.json" ] && echo 0 || echo 1)" \
    "a later report run succeeds after failure-path lock cleanup"

# A signal delivered after mkdir publishes the lock directory but before the
# owner globals are copied is recorded and honored after acquisition completes.
COLLECTION_ACQUIRE_STUBS="$TEST_OUTPUT_DIR/collection-acquire-stubs"
COLLECTION_ACQUIRE_REPORT="$TEST_OUTPUT_DIR/collection-acquire-report"
COLLECTION_ACQUIRE_READY="$TEST_OUTPUT_DIR/collection-acquire-ready"
COLLECTION_ACQUIRE_RELEASE="$TEST_OUTPUT_DIR/collection-acquire-release"
COLLECTION_ACQUIRE_OUT="$TEST_OUTPUT_DIR/collection-acquire.out"
mkdir -p "$COLLECTION_ACQUIRE_STUBS"
cat > "$COLLECTION_ACQUIRE_STUBS/mkdir" << 'STUB'
#!/bin/bash
target="${!#}"
"$COLLECTION_ACQUIRE_REAL_MKDIR" "$@" || exit $?
if [ "$target" = "$COLLECTION_ACQUIRE_REPORT/.selected-analysis.lock" ]; then
    : > "$COLLECTION_ACQUIRE_READY"
    while [ ! -e "$COLLECTION_ACQUIRE_RELEASE" ]; do
        sleep 0.05
    done
fi
STUB
chmod +x "$COLLECTION_ACQUIRE_STUBS/mkdir"
env PATH="$COLLECTION_ACQUIRE_STUBS:$STUB_DIR:$PATH" \
    COLLECTION_ACQUIRE_REAL_MKDIR="$(command -v mkdir)" \
    COLLECTION_ACQUIRE_REPORT="$COLLECTION_ACQUIRE_REPORT" \
    COLLECTION_ACQUIRE_READY="$COLLECTION_ACQUIRE_READY" \
    COLLECTION_ACQUIRE_RELEASE="$COLLECTION_ACQUIRE_RELEASE" \
    "$GH_PR_ENRICH" 1 --output-dir "$COLLECTION_ACQUIRE_REPORT" \
    > "$COLLECTION_ACQUIRE_OUT" 2>&1 &
RUNTIME_BACKGROUND_PID=$!
for _ in $(seq 1 200); do
    [ -e "$COLLECTION_ACQUIRE_READY" ] && break
    sleep 0.05
done
assert_true "$([ -e "$COLLECTION_ACQUIRE_READY" ] && echo 0 || echo 1)" \
    "the acquisition fixture reaches the owner-publication window"
kill -TERM "$RUNTIME_BACKGROUND_PID"
: > "$COLLECTION_ACQUIRE_RELEASE"
rc=0
wait "$RUNTIME_BACKGROUND_PID" || rc=$?
RUNTIME_BACKGROUND_PID=""
assert_eq "143" "$rc" \
    "a signal during lock acquisition is honored after ownership is published"
COLLECTION_ACQUIRE_RESIDUE=$(find "$COLLECTION_ACQUIRE_REPORT" -maxdepth 1 \
    \( -name '.selected-analysis.lock' -o \
       -name '.selected-analysis-release.*' \) -print -quit)
assert_true "$([ -z "$COLLECTION_ACQUIRE_RESIDUE" ] && echo 0 || echo 1)" \
    "signal-during-acquisition cleanup leaves no ownerless lock residue"

# Signal cleanup uses the lock protocol's EXIT retry when its first release
# attempt reaches a transient, authenticated release directory. The managed
# GitHub child is deliberately never released by the test: cancellation must
# terminate it directly rather than waiting for network work to return.
COLLECTION_SIGNAL_STUBS="$TEST_OUTPUT_DIR/collection-signal-stubs"
COLLECTION_SIGNAL_REPORT="$TEST_OUTPUT_DIR/collection-signal-report"
COLLECTION_SIGNAL_READY="$TEST_OUTPUT_DIR/collection-signal-ready"
COLLECTION_SIGNAL_RM_FAILED="$TEST_OUTPUT_DIR/collection-signal-rm-failed"
COLLECTION_SIGNAL_RM_READY="$TEST_OUTPUT_DIR/collection-signal-rm-ready"
COLLECTION_SIGNAL_RM_RELEASE="$TEST_OUTPUT_DIR/collection-signal-rm-release"
COLLECTION_SIGNAL_OUT="$TEST_OUTPUT_DIR/collection-signal.out"
mkdir -p "$COLLECTION_SIGNAL_STUBS"
cat > "$COLLECTION_SIGNAL_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr view" ]; then
    : > "$COLLECTION_SIGNAL_READY"
    while true; do
        sleep 0.05
    done
fi
exec "$COLLECTION_SIGNAL_BASE_GH" "$@"
STUB
cat > "$COLLECTION_SIGNAL_STUBS/rm" << 'STUB'
#!/bin/bash
for candidate in "$@"; do
    case "$candidate" in
        "$COLLECTION_SIGNAL_REPORT"/.selected-analysis-release.*/owner)
            if [ ! -e "$COLLECTION_SIGNAL_RM_FAILED" ]; then
                : > "$COLLECTION_SIGNAL_RM_FAILED"
                : > "$COLLECTION_SIGNAL_RM_READY"
                while [ ! -e "$COLLECTION_SIGNAL_RM_RELEASE" ]; do
                    sleep 0.05
                done
                exit 79
            fi
            ;;
    esac
done
exec "$COLLECTION_SIGNAL_REAL_RM" "$@"
STUB
chmod +x "$COLLECTION_SIGNAL_STUBS/gh" "$COLLECTION_SIGNAL_STUBS/rm"
env PATH="$COLLECTION_SIGNAL_STUBS:$STUB_DIR:$PATH" \
    COLLECTION_SIGNAL_BASE_GH="$STUB_DIR/gh" \
    COLLECTION_SIGNAL_READY="$COLLECTION_SIGNAL_READY" \
    COLLECTION_SIGNAL_REPORT="$COLLECTION_SIGNAL_REPORT" \
    COLLECTION_SIGNAL_RM_FAILED="$COLLECTION_SIGNAL_RM_FAILED" \
    COLLECTION_SIGNAL_RM_READY="$COLLECTION_SIGNAL_RM_READY" \
    COLLECTION_SIGNAL_RM_RELEASE="$COLLECTION_SIGNAL_RM_RELEASE" \
    COLLECTION_SIGNAL_REAL_RM="$(command -v rm)" \
    "$GH_PR_ENRICH" 1 --output-dir "$COLLECTION_SIGNAL_REPORT" \
    > "$COLLECTION_SIGNAL_OUT" 2>&1 &
RUNTIME_BACKGROUND_PID=$!
for _ in $(seq 1 200); do
    [ ! -e "$COLLECTION_SIGNAL_READY" ] || break
    sleep 0.05
done
assert_true "$([ -e "$COLLECTION_SIGNAL_READY" ] && echo 0 || echo 1)" \
    "the signal fixture reaches collection while holding the report lock"
kill -TERM "$RUNTIME_BACKGROUND_PID"
for _ in $(seq 1 200); do
    [ -e "$COLLECTION_SIGNAL_RM_READY" ] && break
    sleep 0.05
done
assert_true "$([ -e "$COLLECTION_SIGNAL_RM_READY" ] && echo 0 || echo 1)" \
    "TERM stops the managed GitHub child and reaches report lock cleanup"
kill -TERM "$RUNTIME_BACKGROUND_PID"
: > "$COLLECTION_SIGNAL_RM_RELEASE"
rc=0
wait "$RUNTIME_BACKGROUND_PID" || rc=$?
RUNTIME_BACKGROUND_PID=""
assert_eq "143" "$rc" \
    "TERM during input collection preserves the conventional exit status"
assert_true "$([ -e "$COLLECTION_SIGNAL_RM_FAILED" ] && echo 0 || echo 1)" \
    "the signal regression exercises a transient first lock-release failure"
COLLECTION_SIGNAL_RESIDUE=$(find "$COLLECTION_SIGNAL_REPORT" -maxdepth 1 \
    \( -name '.selected-analysis.lock' -o \
       -name '.selected-analysis-release.*' \) -print -quit)
assert_true "$([ -z "$COLLECTION_SIGNAL_RESIDUE" ] && echo 0 || echo 1)" \
    "EXIT retries signal cleanup and leaves no report lock residue"

# A DEBUG hook signals the parent immediately before `command_pid=$!`, making
# the launch-to-publication boundary deterministic rather than scheduler-
# dependent. The starting-state guard must defer cleanup until that exact child
# PID is known.
CHILD_START_STUBS="$TEST_OUTPUT_DIR/child-start-stubs"
CHILD_START_REPORT="$TEST_OUTPUT_DIR/child-start-report"
CHILD_START_PID_FILE="$TEST_OUTPUT_DIR/child-start.pid"
CHILD_START_BASH_ENV="$TEST_OUTPUT_DIR/child-start-bash-env"
CHILD_START_HOOK_MARKER="$TEST_OUTPUT_DIR/child-start-hook-fired"
mkdir -p "$CHILD_START_STUBS"
cat > "$CHILD_START_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr view" ]; then
    printf '%s\n' "$$" > "$CHILD_START_PID_FILE"
    while true; do
        sleep 0.05
    done
fi
exec "$CHILD_START_BASE_GH" "$@"
STUB
cat > "$CHILD_START_BASH_ENV" << 'STUB'
__gh_pr_enrich_child_start_debug() {
    if [ "$BASH_COMMAND" = 'command_pid=$!' ] && \
       [ ! -e "$CHILD_START_HOOK_MARKER" ]; then
        : > "$CHILD_START_HOOK_MARKER"
        for _child_start_wait in $(seq 1 200); do
            [ -e "$CHILD_START_PID_FILE" ] && break
            sleep 0.05
        done
        kill -TERM "$$"
    fi
}
set -T
trap '__gh_pr_enrich_child_start_debug' DEBUG
STUB
chmod +x "$CHILD_START_STUBS/gh"
env PATH="$CHILD_START_STUBS:$STUB_DIR:$PATH" \
    BASH_ENV="$CHILD_START_BASH_ENV" \
    CHILD_START_BASE_GH="$STUB_DIR/gh" \
    CHILD_START_PID_FILE="$CHILD_START_PID_FILE" \
    CHILD_START_HOOK_MARKER="$CHILD_START_HOOK_MARKER" \
    "$GH_PR_ENRICH" 1 --output-dir "$CHILD_START_REPORT" \
    >/dev/null 2>&1 &
RUNTIME_BACKGROUND_PID=$!
for _ in $(seq 1 200); do
    kill -0 "$RUNTIME_BACKGROUND_PID" 2>/dev/null || break
    sleep 0.05
done
if kill -0 "$RUNTIME_BACKGROUND_PID" 2>/dev/null; then
    kill -KILL "$RUNTIME_BACKGROUND_PID" 2>/dev/null || true
fi
rc=0
wait "$RUNTIME_BACKGROUND_PID" || rc=$?
RUNTIME_BACKGROUND_PID=""
assert_true "$([ -e "$CHILD_START_HOOK_MARKER" ] && echo 0 || echo 1)" \
    "the child-start regression signals at the pre-publication boundary"
assert_eq "143" "$rc" \
    "a signal during child PID publication is deferred then honored"
CHILD_START_PID=$(cat "$CHILD_START_PID_FILE")
CHILD_START_REAPED=true
if kill -0 "$CHILD_START_PID" 2>/dev/null; then
    CHILD_START_REAPED=false
    kill -KILL "$CHILD_START_PID" 2>/dev/null || true
fi
assert_true "$([ "$CHILD_START_REAPED" = true ] && \
    [ ! -e "$CHILD_START_REPORT/.selected-analysis.lock" ] && echo 0 || echo 1)" \
    "child-start cancellation reaps the writer and releases its report lock"
rm -f "$CHILD_START_PID_FILE"
CHILD_START_PID_FILE=""

# A rejected contender owns no cleanup authority. It must leave the active
# owner's random linked-pagination staging intact until that owner resumes.
LINKED_CONCURRENT_STUBS="$TEST_OUTPUT_DIR/linked-concurrent-stubs"
LINKED_CONCURRENT_REPORT="$TEST_OUTPUT_DIR/linked-concurrent-report"
LINKED_CONCURRENT_READY="$TEST_OUTPUT_DIR/linked-concurrent-ready"
LINKED_CONCURRENT_RELEASE="$TEST_OUTPUT_DIR/linked-concurrent-release"
mkdir -p "$LINKED_CONCURRENT_STUBS"
cat > "$LINKED_CONCURRENT_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "api graphql" ]; then
    case "$*" in
        *closingIssuesReferences*)
            if [ ! -e "$LINKED_CONCURRENT_READY" ]; then
                : > "$LINKED_CONCURRENT_READY"
                while [ ! -e "$LINKED_CONCURRENT_RELEASE" ]; do
                    sleep 0.05
                done
            fi
            ;;
    esac
fi
exec "$LINKED_CONCURRENT_BASE_GH" "$@"
STUB
chmod +x "$LINKED_CONCURRENT_STUBS/gh"
env PATH="$LINKED_CONCURRENT_STUBS:$STUB_DIR:$PATH" \
    LINKED_CONCURRENT_BASE_GH="$STUB_DIR/gh" \
    LINKED_CONCURRENT_READY="$LINKED_CONCURRENT_READY" \
    LINKED_CONCURRENT_RELEASE="$LINKED_CONCURRENT_RELEASE" \
    "$GH_PR_ENRICH" 1 --output-dir "$LINKED_CONCURRENT_REPORT" \
    >/dev/null 2>&1 &
RUNTIME_BACKGROUND_PID=$!
for _ in $(seq 1 200); do
    [ -e "$LINKED_CONCURRENT_READY" ] && break
    sleep 0.05
done
assert_true "$([ -e "$LINKED_CONCURRENT_READY" ] && echo 0 || echo 1)" \
    "the linked concurrency owner reaches private pagination staging"
LINKED_OWNER_STAGE_BEFORE=$(find "$LINKED_CONCURRENT_REPORT" -maxdepth 1 \
    \( -name 'linked-issues.json.pages.*' -o \
       -name 'linked-issues.json.normalized.*' \) -type f | sort)
assert_eq "2" "$(printf '%s\n' "$LINKED_OWNER_STAGE_BEFORE" | \
    sed '/^$/d' | wc -l | tr -d ' ')" \
    "the owner has both linked-pagination staging files"
rc=0
LINKED_CONTENDER_OUT=$(env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" 1 \
    --output-dir "$LINKED_CONCURRENT_REPORT" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a contender is rejected while linked pagination owns the report"
assert_contains "$LINKED_CONTENDER_OUT" "input collection is already active" \
    "the linked-pagination contender fails at report ownership"
LINKED_OWNER_STAGE_AFTER=$(find "$LINKED_CONCURRENT_REPORT" -maxdepth 1 \
    \( -name 'linked-issues.json.pages.*' -o \
       -name 'linked-issues.json.normalized.*' \) -type f | sort)
assert_eq "$LINKED_OWNER_STAGE_BEFORE" "$LINKED_OWNER_STAGE_AFTER" \
    "the rejected contender cannot delete the owner's pagination staging"
: > "$LINKED_CONCURRENT_RELEASE"
rc=0
wait "$RUNTIME_BACKGROUND_PID" || rc=$?
RUNTIME_BACKGROUND_PID=""
assert_true "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" \
    "the linked-pagination owner completes after its contender is rejected"
assert_jq "$LINKED_CONCURRENT_REPORT/linked-issues-status.json" \
    '.status == "completed"' \
    "the owner publishes complete linked-issue coverage"

# Linked-issue pagination uses private random staging files. Report-level
# cancellation must remove them before releasing the lock so an immediate
# retry passes output preflight and cannot observe partial issue intent.
LINKED_SIGNAL_STUBS="$TEST_OUTPUT_DIR/linked-signal-stubs"
LINKED_SIGNAL_REPORT="$TEST_OUTPUT_DIR/linked-signal-report"
LINKED_SIGNAL_READY="$TEST_OUTPUT_DIR/linked-signal-ready"
mkdir -p "$LINKED_SIGNAL_STUBS"
cat > "$LINKED_SIGNAL_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "api graphql" ]; then
    case "$*" in
        *closingIssuesReferences*)
            : > "$LINKED_SIGNAL_READY"
            while true; do
                sleep 0.05
            done
            ;;
    esac
fi
exec "$LINKED_SIGNAL_BASE_GH" "$@"
STUB
chmod +x "$LINKED_SIGNAL_STUBS/gh"
env PATH="$LINKED_SIGNAL_STUBS:$STUB_DIR:$PATH" \
    LINKED_SIGNAL_BASE_GH="$STUB_DIR/gh" \
    LINKED_SIGNAL_READY="$LINKED_SIGNAL_READY" \
    "$GH_PR_ENRICH" 1 --output-dir "$LINKED_SIGNAL_REPORT" \
    >/dev/null 2>&1 &
RUNTIME_BACKGROUND_PID=$!
for _ in $(seq 1 200); do
    [ -e "$LINKED_SIGNAL_READY" ] && break
    sleep 0.05
done
assert_true "$([ -e "$LINKED_SIGNAL_READY" ] && echo 0 || echo 1)" \
    "the linked-issue cancellation fixture reaches private pagination staging"
kill -TERM "$RUNTIME_BACKGROUND_PID"
rc=0
wait "$RUNTIME_BACKGROUND_PID" || rc=$?
RUNTIME_BACKGROUND_PID=""
assert_eq "143" "$rc" \
    "TERM during linked-issue pagination cancels the report run"
LINKED_SIGNAL_RESIDUE=$(find "$LINKED_SIGNAL_REPORT" -maxdepth 1 \
    \( -name 'linked-issues.json.pages.*' -o \
       -name 'linked-issues.json.normalized.*' -o \
       -name '.selected-analysis.lock' \) -print -quit)
assert_true "$([ -z "$LINKED_SIGNAL_RESIDUE" ] && echo 0 || echo 1)" \
    "linked-issue cancellation removes private staging and lock residue"
env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" 1 \
    --output-dir "$LINKED_SIGNAL_REPORT" >/dev/null 2>&1
assert_true "$([ -f "$LINKED_SIGNAL_REPORT/linked-issues.json" ] && echo 0 || echo 1)" \
    "an immediate retry succeeds after linked-issue cancellation cleanup"

STALE_LINKED_REPORT="$TEST_OUTPUT_DIR/stale-linked-report"
mkdir -p "$STALE_LINKED_REPORT"
printf 'partial\n' > "$STALE_LINKED_REPORT/linked-issues.json.pages.A1b2C3"
printf 'partial\n' > "$STALE_LINKED_REPORT/linked-issues.json.normalized.Z9y8X7"
env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" 1 \
    --output-dir "$STALE_LINKED_REPORT" >/dev/null 2>&1
STALE_LINKED_RESIDUE=$(find "$STALE_LINKED_REPORT" -maxdepth 1 \
    \( -name 'linked-issues.json.pages.*' -o \
       -name 'linked-issues.json.normalized.*' \) -print -quit)
assert_true "$([ -z "$STALE_LINKED_RESIDUE" ] && echo 0 || echo 1)" \
    "a new lock owner recovers exact-name pagination staging from a crashed run"

PERSISTENT_RM_STUBS="$TEST_OUTPUT_DIR/persistent-pagination-rm-stubs"
PERSISTENT_RM_REPORT="$TEST_OUTPUT_DIR/persistent-pagination-rm-report"
mkdir -p "$PERSISTENT_RM_STUBS"
cat > "$PERSISTENT_RM_STUBS/rm" << 'STUB'
#!/bin/bash
for candidate in "$@"; do
    case "$candidate" in
        "$PERSISTENT_RM_REPORT"/linked-issues.json.pages.*|\
        "$PERSISTENT_RM_REPORT"/linked-issues.json.normalized.*)
            exit 81
            ;;
    esac
done
exec "$PERSISTENT_RM_REAL" "$@"
STUB
chmod +x "$PERSISTENT_RM_STUBS/rm"
rc=0
PERSISTENT_RM_OUT=$(env PATH="$PERSISTENT_RM_STUBS:$STUB_DIR:$PATH" \
    PERSISTENT_RM_REPORT="$PERSISTENT_RM_REPORT" \
    PERSISTENT_RM_REAL="$(command -v rm)" \
    "$GH_PR_ENRICH" 1 --output-dir "$PERSISTENT_RM_REPORT" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "persistent pagination cleanup failure fails the report run"
assert_contains "$PERSISTENT_RM_OUT" "pagination staging remains" \
    "persistent pagination cleanup failure is visible to the operator"
env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" 1 \
    --output-dir "$PERSISTENT_RM_REPORT" >/dev/null 2>&1
PERSISTENT_RM_RESIDUE=$(find "$PERSISTENT_RM_REPORT" -maxdepth 1 \
    \( -name 'linked-issues.json.pages.*' -o \
       -name 'linked-issues.json.normalized.*' -o \
       -name '.selected-analysis.lock' \) -print -quit)
assert_true "$([ -z "$PERSISTENT_RM_RESIDUE" ] && echo 0 || echo 1)" \
    "the next owner recovers a dead lock and persistent pagination residue"

rc=0
PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" --test-call verify_pr_head_unchanged \
    1 wrong-head >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "hosted head revalidation detects a PR push during input collection"

SYMLINK_OUTPUT="$TEST_OUTPUT_DIR/symlink-output"
mkdir -p "$SYMLINK_OUTPUT"
echo "do not overwrite" > "$TEST_OUTPUT_DIR/symlink-target.txt"
ln -s ../symlink-target.txt "$SYMLINK_OUTPUT/pr-summary.json"
rc=0
SYMLINK_OUT=$(env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" 1 \
    --output-dir "$SYMLINK_OUTPUT" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "report generation rejects a branch-supplied output symlink before writing"
assert_eq "do not overwrite" "$(cat "$TEST_OUTPUT_DIR/symlink-target.txt")" \
    "rejected report symlink leaves its target untouched"
assert_contains "$SYMLINK_OUT" "symbolic link" \
    "the unsafe output error identifies the symlink"

mkdir -p "$TEST_OUTPUT_DIR/parent-symlink-target"
ln -s parent-symlink-target "$TEST_OUTPUT_DIR/report-parent-link"
rc=0
PARENT_SYMLINK_OUT=$(env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" 1 \
    --output-dir "$TEST_OUTPUT_DIR/report-parent-link/nested" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "report generation rejects a symbolic-link parent before creating directories"
assert_true "$([ ! -e "$TEST_OUTPUT_DIR/parent-symlink-target/nested" ] && echo 0 || echo 1)" \
    "rejected symbolic-link parent creates no directory in its target"
assert_contains "$PARENT_SYMLINK_OUT" "symbolic-link component" \
    "the unsafe output error identifies a symlinked parent path"

rc=0
TRAILING_SYMLINK_OUT=$(env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" 1 \
    --output-dir "$TEST_OUTPUT_DIR/report-parent-link/" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a trailing slash cannot hide a symbolic-link output directory"
assert_contains "$TRAILING_SYMLINK_OUT" "symbolic-link component" \
    "the trailing-slash rejection identifies the symbolic-link path"

# macOS implements /tmp as a root-level operating-system alias to /private/tmp.
# That trusted platform link must not make all standard temporary output paths
# unusable, while the nested user-controlled link above remains rejected.
env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" 1 \
    --output-dir "$TMP_ALIAS_OUTPUT" >/dev/null 2>&1
assert_true "$([ -f "$TMP_ALIAS_OUTPUT/pr-summary.json" ] && echo 0 || echo 1)" \
    "standard temporary output paths work through a root-level system alias"
TRACKED_OUTPUT_REPO="$TEST_OUTPUT_DIR/tracked-output-repo"
mkdir -p "$TRACKED_OUTPUT_REPO/report"
echo "branch supplied" > "$TRACKED_OUTPUT_REPO/report/pr-summary.json"
(cd "$TRACKED_OUTPUT_REPO" && git init -q . && git config user.email t@t && \
    git config user.name t && git add -A && git commit -qm init)
rc=0
TRACKED_OUTPUT_OUT=$( (cd "$TRACKED_OUTPUT_REPO" && env PATH="$STUB_DIR:$PATH" \
    "$GH_PR_ENRICH" 1 --output-dir report 2>&1) ) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "report generation rejects artifacts tracked by the reviewed branch"
assert_eq "branch supplied" "$(cat "$TRACKED_OUTPUT_REPO/report/pr-summary.json")" \
    "rejected tracked report artifact is not overwritten"
assert_contains "$TRACKED_OUTPUT_OUT" "tracked by the reviewed branch" \
    "the unsafe output error identifies tracked branch content"

NO_CLAUDE_BIN="$TEST_OUTPUT_DIR/no-claude-bin"
mkdir -p "$NO_CLAUDE_BIN"
ln -s "$STUB_DIR/gh" "$NO_CLAUDE_BIN/gh"
ln -s "$STUB_DIR/timeout" "$NO_CLAUDE_BIN/timeout"
ln -s "$(command -v jq)" "$NO_CLAUDE_BIN/jq"
rc=0
NO_CLAUDE_OUT=$(env PATH="$NO_CLAUDE_BIN:/usr/bin:/bin" REPO_VISIBILITY=PUBLIC \
    "$GH_PR_ENRICH" 1 --enrich --output-dir "$TEST_OUTPUT_DIR/no-claude-report" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "requested Claude enrichment fails when the provider is unavailable"
assert_contains "$NO_CLAUDE_OUT" "requested enrichment cannot run" \
    "missing Claude cannot silently surface a stale selected result"

PREPARED="$TEST_OUTPUT_DIR/prepared"
PREP_OUT=$(env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" 1 --prepare-analysis --diff \
    --output-dir "$PREPARED" 2>&1)

assert_jq "$PREPARED/analysis-context.json" '.code_changes.file_diffs | length == 1' \
    "--prepare-analysis --diff creates a provider-neutral context without Claude"
assert_jq "$PREPARED/analysis-schema.json" '.type == "object"' \
    "context preparation emits the shared structured-output schema"
assert_jq "$PREPARED/analysis-context.json" '.coverage.diff.status == "completed"' \
    "successful diff preparation is recorded as completed coverage"
assert_jq "$PREPARED/analysis-context.json" '.pr.repository == "o/r" and .pr.number == 1' \
    "the fingerprinted context binds repository and PR identity"
assert_not_contains "$PREP_OUT" "Claude analysis" \
    "context preparation does not invoke an external analyzer"

SAST_WORKSPACE="$TEST_OUTPUT_DIR/sast-workspace"
SAST_PREPARED="$SAST_WORKSPACE/reports"
mkdir -p "$SAST_WORKSPACE"
cp "$GH_PR_ENRICH" "$SAST_WORKSPACE/gh-pr-enrich"
(cd "$SAST_WORKSPACE" && git init -q . && git config user.email t@t && \
    git config user.name t && git add gh-pr-enrich && git commit -qm init)
(cd "$SAST_WORKSPACE" && env PATH="$STUB_DIR:$PATH" \
    GH_PR_ENRICH_CODE_ACCESS=true \
    "$GH_PR_ENRICH" 1 --prepare-analysis --sast \
    --output-dir reports >/dev/null 2>&1)
assert_jq "$SAST_PREPARED/analysis-context.json" \
    '.sast_findings | length == 1' \
    "--prepare-analysis --sast includes fresh Semgrep findings in the shared context"
assert_jq "$SAST_PREPARED/analysis-context.json" '.coverage.sast.status == "completed"' \
    "successful SAST preparation is distinguished from a skipped clean result"

PRIVATE_OUT_DIR="$TEST_OUTPUT_DIR/private"
CLAUDE_LOG="$TEST_OUTPUT_DIR/claude-invoked.txt"
rc=0
PRIVATE_OUT=$(env PATH="$STUB_DIR:$PATH" REPO_VISIBILITY=PRIVATE CLAUDE_INVOKED_LOG="$CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --output-dir "$PRIVATE_OUT_DIR" 2>&1) || rc=$?

assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "private-repository enrichment fails closed without disclosure authorization"
assert_true "$([ ! -s "$CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "private PR data is not sent to Claude without --allow-external"
assert_contains "$PRIVATE_OUT" "--allow-external" \
    "the disclosure gate explains how to authorize the external analyzer"

for VISIBILITY in INTERNAL UNKNOWN; do
    visibility_slug=$(printf '%s' "$VISIBILITY" | tr '[:upper:]' '[:lower:]')
    VISIBILITY_DIR="$TEST_OUTPUT_DIR/$visibility_slug"
    rc=0
    VISIBILITY_OUT=$(env PATH="$STUB_DIR:$PATH" REPO_VISIBILITY="$VISIBILITY" \
        CLAUDE_INVOKED_LOG="$VISIBILITY_DIR/claude-invoked.txt" \
        "$GH_PR_ENRICH" 1 --enrich --output-dir "$VISIBILITY_DIR" 2>&1) || rc=$?
    assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
        "$VISIBILITY repository enrichment fails closed without authorization"
    assert_true "$([ ! -s "$VISIBILITY_DIR/claude-invoked.txt" ] && echo 0 || echo 1)" \
        "$VISIBILITY PR data is not sent to Claude without --allow-external"
    assert_contains "$VISIBILITY_OUT" "$VISIBILITY" \
        "$VISIBILITY disclosure failure identifies the repository visibility"
done

AUTHORIZED_DIR="$TEST_OUTPUT_DIR/private-authorized"
env PATH="$STUB_DIR:$PATH" REPO_VISIBILITY=PRIVATE GH_PR_ENRICH_CODE_ACCESS=false \
    CLAUDE_INVOKED_LOG="$CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --allow-external --diff \
    --output-dir "$AUTHORIZED_DIR" >/dev/null 2>&1

assert_true "$([ -s "$CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "--allow-external authorizes Claude for a private repository"
assert_jq "$AUTHORIZED_DIR/analysis.json" '._metadata.repository_visibility == "PRIVATE"' \
    "the analysis provenance records repository visibility"

# The provider's combined-data publication uses the same no-clobber
# transaction as selection/invalidation. A noncooperating destination that
# appears after quarantine is preserved and aborts enrichment.
PROVIDER_COLLISION_DIR="$TEST_OUTPUT_DIR/provider-collision"
PROVIDER_COLLISION_STUBS="$TEST_OUTPUT_DIR/provider-collision-stubs"
PROVIDER_COLLISION_MARKER="$TEST_OUTPUT_DIR/provider-collision-fired"
mkdir -p "$PROVIDER_COLLISION_STUBS"
cat > "$PROVIDER_COLLISION_STUBS/mv" << 'STUB'
#!/bin/bash
"$REAL_MV" "$@" || exit $?
case "$1:$2" in
    "$PROVIDER_COLLISION_REPORT/combined-data.json:"*\
"/.selected-analysis-quarantine."*"/combined-data.json")
        if [ -f "$PROVIDER_COLLISION_REPORT/claude-analysis.json" ] && \
           [ ! -f "$PROVIDER_COLLISION_MARKER" ]; then
            : > "$PROVIDER_COLLISION_MARKER"
            printf '%s\n' '{"concurrent_provider_replacement":true}' \
                > "$PROVIDER_COLLISION_REPORT/combined-data.json"
        fi
        ;;
esac
STUB
chmod +x "$PROVIDER_COLLISION_STUBS/mv"
rc=0
env PATH="$PROVIDER_COLLISION_STUBS:$STUB_DIR:$PATH" \
    REAL_MV="$(command -v mv)" REPO_VISIBILITY=PRIVATE \
    GH_PR_ENRICH_CODE_ACCESS=false CLAUDE_INVOKED_LOG="$CLAUDE_LOG" \
    PROVIDER_COLLISION_REPORT="$PROVIDER_COLLISION_DIR" \
    PROVIDER_COLLISION_MARKER="$PROVIDER_COLLISION_MARKER" \
    "$GH_PR_ENRICH" 1 --enrich --allow-external \
    --output-dir "$PROVIDER_COLLISION_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ -f "$PROVIDER_COLLISION_MARKER" ] && \
    echo 0 || echo 1)" \
    "provider combined-data publication aborts on a boundary collision"
assert_jq "$PROVIDER_COLLISION_DIR/combined-data.json" \
    '.concurrent_provider_replacement == true' \
    "provider publication never clobbers a concurrent combined-data replacement"
PROVIDER_COLLISION_QUARANTINE=$(find "$PROVIDER_COLLISION_DIR" -maxdepth 1 \
    -name '.selected-analysis-quarantine.*' -print -quit)
assert_true "$([ -n "$PROVIDER_COLLISION_QUARANTINE" ] && \
    [ -f "$PROVIDER_COLLISION_QUARANTINE/combined-data.json" ] && \
    echo 0 || echo 1)" \
    "provider collision preserves the original combined view for reconciliation"

# Read-only freezing binds each copied file to the initial baseline, not merely
# to a later live value. A coherent A->B->A swap during cp cannot return B while
# both outer identity checks observe A.
READ_ABA_DIR="$TEST_OUTPUT_DIR/read-only-aba"
READ_ABA_STUBS="$TEST_OUTPUT_DIR/read-only-aba-stubs"
mkdir -p "$READ_ABA_DIR" "$READ_ABA_STUBS"
cp "$AUTHORIZED_DIR/analysis.json" "$READ_ABA_DIR/analysis.json"
cp "$AUTHORIZED_DIR/analysis-context.json" "$READ_ABA_DIR/analysis-context.json"
cp "$AUTHORIZED_DIR/pr-summary.json" "$READ_ABA_DIR/pr-summary.json"
cp "$READ_ABA_DIR/analysis.json" "$TEST_OUTPUT_DIR/read-aba-analysis-a.json"
cp "$READ_ABA_DIR/analysis-context.json" "$TEST_OUTPUT_DIR/read-aba-context-a.json"
jq 'del(.coverage.context_fingerprint)
    | .issue_comments += [{user:"aba",body:"state-b",url:"u",created_at:"t"}]' \
    "$READ_ABA_DIR/analysis-context.json" > "$TEST_OUTPUT_DIR/read-aba-context-b.tmp.json"
READ_ABA_FINGERPRINT=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
    "$TEST_OUTPUT_DIR/read-aba-context-b.tmp.json")
jq --arg fingerprint "$READ_ABA_FINGERPRINT" \
    '.coverage.context_fingerprint = $fingerprint' \
    "$TEST_OUTPUT_DIR/read-aba-context-b.tmp.json" \
    > "$TEST_OUTPUT_DIR/read-aba-context-b.json"
jq --arg fingerprint "$READ_ABA_FINGERPRINT" \
    '._metadata.context_fingerprint = $fingerprint
     | .task_list = [{priority:"low",task:"state-b",thread_ids:[],file:"a.js",
        line:1,suggested_fix:"b",verification:"b"}]' \
    "$READ_ABA_DIR/analysis.json" > "$TEST_OUTPUT_DIR/read-aba-analysis-b.json"
cat > "$READ_ABA_STUBS/cp" << 'STUB'
#!/bin/bash
copy_source=""
previous=""
for argument in "$@"; do
    copy_source="$previous"
    previous="$argument"
done
if [ "$copy_source" = "$READ_ABA_REPORT/analysis.json" ]; then
    "$REAL_CP" "$READ_ABA_ANALYSIS_B" "$READ_ABA_REPORT/analysis.json"
    "$REAL_CP" "$READ_ABA_CONTEXT_B" "$READ_ABA_REPORT/analysis-context.json"
    "$REAL_CP" "$@" || exit $?
    "$REAL_CP" "$READ_ABA_ANALYSIS_A" "$READ_ABA_REPORT/analysis.json"
    "$REAL_CP" "$READ_ABA_CONTEXT_A" "$READ_ABA_REPORT/analysis-context.json"
    exit 0
fi
exec "$REAL_CP" "$@"
STUB
chmod +x "$READ_ABA_STUBS/cp"
rc=0
READ_ABA_SELECTED=$(env PATH="$READ_ABA_STUBS:$PATH" \
    REAL_CP="$(command -v cp)" READ_ABA_REPORT="$READ_ABA_DIR" \
    READ_ABA_ANALYSIS_A="$TEST_OUTPUT_DIR/read-aba-analysis-a.json" \
    READ_ABA_CONTEXT_A="$TEST_OUTPUT_DIR/read-aba-context-a.json" \
    READ_ABA_ANALYSIS_B="$TEST_OUTPUT_DIR/read-aba-analysis-b.json" \
    READ_ABA_CONTEXT_B="$TEST_OUTPUT_DIR/read-aba-context-b.json" \
    "$GH_PR_ENRICH" --test-call select_analysis_file \
    "$READ_ABA_DIR" read-only 2>/dev/null) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ -z "$READ_ABA_SELECTED" ] && echo 0 || echo 1)" \
    "read-only selection rejects a coherent analysis/context ABA during copy"
assert_true "$(cmp -s "$READ_ABA_DIR/analysis.json" \
    "$TEST_OUTPUT_DIR/read-aba-analysis-a.json" && \
    cmp -s "$READ_ABA_DIR/analysis-context.json" \
    "$TEST_OUTPUT_DIR/read-aba-context-a.json"; echo $?)" \
    "the ABA fixture restores both live analysis and context to state A"

# Root selection applies the same baseline/copy/live binding to the named
# source artifact. It may accept later mutations, but never bytes observed only
# during an A->B->A copy window.
SELECT_ABA_DIR="$TEST_OUTPUT_DIR/select-source-aba"
SELECT_ABA_STUBS="$TEST_OUTPUT_DIR/select-source-aba-stubs"
mkdir -p "$SELECT_ABA_DIR" "$SELECT_ABA_STUBS"
for SELECT_ABA_VIEW in analysis-context.json pr-summary.json combined-data.json \
        comprehensive-report.md; do
    cp "$AUTHORIZED_DIR/$SELECT_ABA_VIEW" "$SELECT_ABA_DIR/$SELECT_ABA_VIEW"
done
cp "$AUTHORIZED_DIR/analysis.json" "$SELECT_ABA_DIR/candidate.json"
cp "$SELECT_ABA_DIR/candidate.json" "$TEST_OUTPUT_DIR/select-aba-a.json"
jq '.task_list[0].task = "state-b-only"' \
    "$SELECT_ABA_DIR/candidate.json" > "$TEST_OUTPUT_DIR/select-aba-b.json"
cat > "$SELECT_ABA_STUBS/cp" << 'STUB'
#!/bin/bash
copy_source=""
previous=""
for argument in "$@"; do
    copy_source="$previous"
    previous="$argument"
done
if [ "$copy_source" = "$SELECT_ABA_SOURCE" ]; then
    "$REAL_CP" "$SELECT_ABA_B" "$SELECT_ABA_SOURCE"
    "$REAL_CP" "$@" || exit $?
    "$REAL_CP" "$SELECT_ABA_A" "$SELECT_ABA_SOURCE"
    exit 0
fi
exec "$REAL_CP" "$@"
STUB
chmod +x "$SELECT_ABA_STUBS/cp"
rc=0
SELECT_ABA_OUT=$(env PATH="$SELECT_ABA_STUBS:$STUB_DIR:$PATH" \
    REAL_CP="$(command -v cp)" \
    SELECT_ABA_SOURCE="$SELECT_ABA_DIR/candidate.json" \
    SELECT_ABA_A="$TEST_OUTPUT_DIR/select-aba-a.json" \
    SELECT_ABA_B="$TEST_OUTPUT_DIR/select-aba-b.json" \
    "$GH_PR_ENRICH" select-analysis "$SELECT_ABA_DIR" \
    "$SELECT_ABA_DIR/candidate.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects a source ABA during immutable copy"
assert_contains "$SELECT_ABA_OUT" "source changed while its immutable copy" \
    "source ABA rejection names the immutable-copy boundary"
assert_true "$([ ! -e "$SELECT_ABA_DIR/analysis.json" ] && \
    cmp -s "$SELECT_ABA_DIR/candidate.json" \
        "$TEST_OUTPUT_DIR/select-aba-a.json" && echo 0 || echo 1)" \
    "source ABA publishes nothing and restores the named state-A source"

# The writer receives the values captured by run_claude_analysis; it must not
# reread a context that may refresh in the narrow gap before publication.
PROVENANCE_DIR="$TEST_OUTPUT_DIR/provenance-race"
mkdir -p "$PROVENANCE_DIR"
cp "$AUTHORIZED_DIR/pr-summary.json" "$PROVENANCE_DIR/pr-summary.json"
CAPTURED_HEAD=$(jq -r '.coverage.code_access.pr_head_sha' "$AUTHORIZED_DIR/analysis-context.json")
CAPTURED_FINGERPRINT=$(jq -r '.coverage.context_fingerprint' "$AUTHORIZED_DIR/analysis-context.json")
jq 'del(._metadata)' "$AUTHORIZED_DIR/claude-analysis.json" > "$PROVENANCE_DIR/raw-analysis.json"
jq 'del(.coverage.context_fingerprint)
    | .issue_comments += [{user:"race",body:"refreshed",url:"u",created_at:"t"}]' \
    "$AUTHORIZED_DIR/analysis-context.json" > "$PROVENANCE_DIR/context.tmp.json"
REFRESHED_FINGERPRINT=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
    "$PROVENANCE_DIR/context.tmp.json")
jq --arg fingerprint "$REFRESHED_FINGERPRINT" \
    '.coverage.context_fingerprint = $fingerprint' \
    "$PROVENANCE_DIR/context.tmp.json" > "$PROVENANCE_DIR/analysis-context.json"
env REPO=o/r PR_NUMBER=1 "$GH_PR_ENRICH" --test-call write_claude_analysis_artifact \
    "$PROVENANCE_DIR/raw-analysis.json" "$PROVENANCE_DIR/claude-analysis.json" \
    PRIVATE "$CAPTURED_HEAD" "$CAPTURED_FINGERPRINT"
assert_jq "$PROVENANCE_DIR/claude-analysis.json" \
    "._metadata.pr_head_sha == \"$CAPTURED_HEAD\" and ._metadata.context_fingerprint == \"$CAPTURED_FINGERPRINT\"" \
    "artifact provenance uses captured values instead of rereading refreshed context"
rc=0
PROVENANCE_RACE_OUT=$(PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" select-analysis \
    "$PROVENANCE_DIR" "$PROVENANCE_DIR/claude-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects captured artifact metadata against a later context refresh"
assert_contains "$PROVENANCE_RACE_OUT" "context fingerprint" \
    "the post-verification context race fails at immutable identity validation"

HYBRID_SOURCE="$AUTHORIZED_DIR/hybrid-analysis.json"
jq '.task_list = [{
        priority: "high", task: "Hybrid-selected task", thread_ids: [],
        file: "a.js", line: 1, suggested_fix: "fix it", verification: "test it"
    }]
    | ._metadata.provider = "hybrid"
    | ._metadata.analyzers = [
        {provider: "codex", role: "orchestrator"},
        {provider: "claude", role: "external"}
    ]' "$AUTHORIZED_DIR/analysis.json" > "$HYBRID_SOURCE"

# Selection performs its own hosted-state check, so all selector calls use the
# deterministic GitHub stub rather than the developer's live checkout.
export PATH="$STUB_DIR:$PATH"

# Untrusted PR prose may contain the marker substring. Only a complete marker
# line inserted by the renderer is allowed to delimit the generated section.
NEAR_MARKER='PR title mentions <!-- BEGIN SELECTED ANALYSIS --> without being a marker'
{
    printf '%s\n' "$NEAR_MARKER"
    cat "$AUTHORIZED_DIR/comprehensive-report.md"
} > "$AUTHORIZED_DIR/comprehensive-report.with-near-marker.md"
mv "$AUTHORIZED_DIR/comprehensive-report.with-near-marker.md" \
    "$AUTHORIZED_DIR/comprehensive-report.md"
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$HYBRID_SOURCE" >/dev/null

assert_jq "$AUTHORIZED_DIR/analysis.json" '._metadata.provider == "hybrid"' \
    "select-analysis promotes a root-verified hybrid artifact"
assert_contains "$(cat "$AUTHORIZED_DIR/comprehensive-report.md")" "$NEAR_MARKER" \
    "a marker substring in untrusted report prose does not truncate the report"
assert_eq "1" "$(grep -c '^<!-- BEGIN SELECTED ANALYSIS -->$' \
    "$AUTHORIZED_DIR/comprehensive-report.md")" \
    "selection publishes exactly one complete selected-analysis begin marker"
assert_eq "1" "$(grep -c '^<!-- END SELECTED ANALYSIS -->$' \
    "$AUTHORIZED_DIR/comprehensive-report.md")" \
    "selection publishes exactly one complete selected-analysis end marker"
assert_contains "$(cat "$AUTHORIZED_DIR/analysis.md")" "Hybrid-selected task" \
    "select-analysis regenerates the selected Markdown report"
assert_jq "$AUTHORIZED_DIR/combined-data.json" \
    '.analysis._metadata.provider == "hybrid" and .analysis.task_list[0].task == "Hybrid-selected task"' \
    "select-analysis refreshes the combined-data selected view"

# Selection also treats writer-lock release as part of success. The first
# owner removal fails; EXIT cleanup retries without hiding the nonzero result.
SELECTION_RELEASE_STUBS="$TEST_OUTPUT_DIR/selection-lock-release-stubs"
SELECTION_RELEASE_MARKER="$TEST_OUTPUT_DIR/selection-lock-release-fired"
mkdir -p "$SELECTION_RELEASE_STUBS"
cat > "$SELECTION_RELEASE_STUBS/rm" << 'STUB'
#!/bin/bash
for candidate in "$@"; do
    case "$candidate" in
        "$SELECTION_RELEASE_REPORT"/.selected-analysis-release.*/owner)
            if [ ! -f "$SELECTION_RELEASE_MARKER" ]; then
                : > "$SELECTION_RELEASE_MARKER"
                exit 79
            fi
            ;;
    esac
done
exec "$REAL_RM" "$@"
STUB
chmod +x "$SELECTION_RELEASE_STUBS/rm"
rc=0
SELECTION_RELEASE_OUT=$(env PATH="$SELECTION_RELEASE_STUBS:$PATH" \
    REAL_RM="$(command -v rm)" \
    SELECTION_RELEASE_REPORT="$AUTHORIZED_DIR" \
    SELECTION_RELEASE_MARKER="$SELECTION_RELEASE_MARKER" \
    "$GH_PR_ENRICH" select-analysis \
    "$AUTHORIZED_DIR" "$HYBRID_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection propagates a writer-lock release failure"
assert_contains "$SELECTION_RELEASE_OUT" \
    "analysis was published, but its writer lock could not be released" \
    "selection reports the post-publication lock-release failure"
assert_true "$([ -f "$SELECTION_RELEASE_MARKER" ] && \
    [ ! -e "$AUTHORIZED_DIR/.selected-analysis.lock" ] && echo 0 || echo 1)" \
    "selection EXIT cleanup retries and removes a transient failed lock"
assert_jq "$AUTHORIZED_DIR/analysis.json" '._metadata.provider == "hybrid"' \
    "selection release failure does not corrupt the published selected artifact"

# Selection enforces the documented impact × likelihood matrix rather than
# accepting independently valid enum values that contradict one another.
VALID_SEVERITY_SOURCE="$AUTHORIZED_DIR/valid-severity-matrix.json"
INVALID_SEVERITY_SOURCE="$AUTHORIZED_DIR/invalid-severity-matrix.json"
jq '
    .issue_categories = ([
      {impact:"severe", likelihood:"certain", severity:"critical"},
      {impact:"severe", likelihood:"likely", severity:"critical"},
      {impact:"severe", likelihood:"possible", severity:"high"},
      {impact:"severe", likelihood:"unlikely", severity:"medium"},
      {impact:"moderate", likelihood:"certain", severity:"high"},
      {impact:"moderate", likelihood:"likely", severity:"high"},
      {impact:"moderate", likelihood:"possible", severity:"medium"},
      {impact:"moderate", likelihood:"unlikely", severity:"low"},
      {impact:"minor", likelihood:"certain", severity:"medium"},
      {impact:"minor", likelihood:"likely", severity:"low"},
      {impact:"minor", likelihood:"possible", severity:"low"},
      {impact:"minor", likelihood:"unlikely", severity:"low"}
    ] | to_entries | map(.value + {
      name:("Matrix tuple " + (.key | tostring)), category:"logic_error",
      severity_rationale:"matrix fixture", verdict:"plausible", confidence:"medium",
      description:"matrix fixture", evidence:[{file:"a.js",line:1,detail:"fixture"}],
      thread_ids:[], sources:["codex:orchestrator"]
    }))
    | .category_coverage |= map(if .category == "logic_error"
        then .verdict = "findings_reported" else . end)
' "$HYBRID_SOURCE" > "$VALID_SEVERITY_SOURCE"
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" \
    "$VALID_SEVERITY_SOURCE" >/dev/null
assert_jq "$AUTHORIZED_DIR/analysis.json" \
    '.issue_categories | length == 12' \
    "selection accepts every documented severity-matrix tuple"
jq '.issue_categories[0].severity = "low"' \
    "$VALID_SEVERITY_SOURCE" > "$INVALID_SEVERITY_SOURCE"
rc=0
INVALID_SEVERITY_OUT=$("$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" \
    "$INVALID_SEVERITY_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects a severity that contradicts impact and likelihood"
assert_contains "$INVALID_SEVERITY_OUT" "missing required findings or provenance" \
    "the invalid severity tuple fails selected-analysis contract validation"
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$HYBRID_SOURCE" >/dev/null

FROZEN_SOURCE="$AUTHORIZED_DIR/freeze-race-analysis.json"
jq '.task_list[0].task = "frozen before hosted verification"' \
    "$HYBRID_SOURCE" > "$FROZEN_SOURCE"
TMPDIR="$AUTHORIZED_DIR" MUTATE_ANALYSIS_SOURCE="$FROZEN_SOURCE" \
    "$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$FROZEN_SOURCE" >/dev/null
assert_jq "$AUTHORIZED_DIR/analysis.json" \
    '.task_list[0].task == "frozen before hosted verification"' \
    "selection publishes the private frozen source when the original changes mid-validation"
assert_jq "$FROZEN_SOURCE" '.task_list[0].task == "mutated after selector freeze"' \
    "the GitHub revalidation stub deterministically mutates the original source"

CONTEXT_RACE_ORIGINAL="$TEST_OUTPUT_DIR/context-race-original.json"
CONTEXT_RACE_TMP="$TEST_OUTPUT_DIR/context-race.tmp.json"
CONTEXT_RACE_REPLACEMENT="$TEST_OUTPUT_DIR/context-race-replacement.json"
CONTEXT_RACE_SOURCE="$AUTHORIZED_DIR/context-race-analysis.json"
cp "$AUTHORIZED_DIR/analysis-context.json" "$CONTEXT_RACE_ORIGINAL"
jq 'del(.coverage.context_fingerprint)
    | .issue_comments += [{user:"race",body:"refreshed",url:"u",created_at:"t"}]' \
    "$CONTEXT_RACE_ORIGINAL" > "$CONTEXT_RACE_TMP"
CONTEXT_RACE_FINGERPRINT=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
    "$CONTEXT_RACE_TMP")
jq --arg fingerprint "$CONTEXT_RACE_FINGERPRINT" \
    '.coverage.context_fingerprint = $fingerprint' \
    "$CONTEXT_RACE_TMP" > "$CONTEXT_RACE_REPLACEMENT"
jq '.task_list[0].task = "must not publish refreshed-context race"' \
    "$HYBRID_SOURCE" > "$CONTEXT_RACE_SOURCE"
rc=0
CONTEXT_SELECTION_RACE_OUT=$(MUTATE_ANALYSIS_CONTEXT="$AUTHORIZED_DIR/analysis-context.json" \
    REPLACEMENT_ANALYSIS_CONTEXT="$CONTEXT_RACE_REPLACEMENT" \
    "$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$CONTEXT_RACE_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects a context refresh during hosted verification"
assert_contains "$CONTEXT_SELECTION_RACE_OUT" "context changed during selection" \
    "the selector reports the live-context publication race"
assert_jq "$AUTHORIZED_DIR/analysis.json" \
    '.task_list[0].task == "frozen before hosted verification"' \
    "a context refresh race preserves the previously selected analysis"
cp "$CONTEXT_RACE_ORIGINAL" "$AUTHORIZED_DIR/analysis-context.json"

UNKNOWN_THREAD_SOURCE="$AUTHORIZED_DIR/unknown-thread-analysis.json"
jq '.task_list[0].thread_ids = ["PRRT_from_another_pr"]' \
    "$HYBRID_SOURCE" > "$UNKNOWN_THREAD_SOURCE"
rc=0
UNKNOWN_THREAD_OUT=$("$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" \
    "$UNKNOWN_THREAD_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects task thread IDs absent from the PR context"
assert_contains "$UNKNOWN_THREAD_OUT" "fingerprinted context" \
    "the unknown-thread rejection is attributed to selected-analysis provenance"

assert_jq "$AUTHORIZED_DIR/analysis-context.json" \
    '.coverage.code_access.state == "disabled"' \
    "the selection fixture records disabled repository code access"
NO_CODE_CONFIRMED_SOURCE="$AUTHORIZED_DIR/no-code-confirmed.json"
jq '.issue_categories = [{
        name: "Unverified finding", category: "logic_error", severity: "high",
        impact: "moderate", likelihood: "likely", severity_rationale: "fixture",
        verdict: "confirmed", confidence: "high", description: "fixture",
        evidence: [{file:"a.js",line:1,detail:"fixture"}], thread_ids: [],
        sources: ["codex:orchestrator"]
    }]
    | .category_coverage |= map(if .category == "logic_error"
        then .verdict = "findings_reported" else . end)' \
    "$HYBRID_SOURCE" > "$NO_CODE_CONFIRMED_SOURCE"
rc=0
NO_CODE_CONFIRMED_OUT=$("$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" \
    "$NO_CODE_CONFIRMED_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "disabled code access prevents publishing confirmed findings"
assert_contains "$NO_CODE_CONFIRMED_OUT" "without enabled repository code access" \
    "the no-code confirmation error identifies the verdict contract"

# Confirmed findings also require the current local workspace to remain the
# exact one captured in the immutable context. An explicit code-access override
# still permits a stable non-head checkout, but it does not waive this binding.
SELECTION_REPO="$TEST_OUTPUT_DIR/selection-workspace"
SELECTION_REPORT="$SELECTION_REPO/report"
mkdir -p "$SELECTION_REPORT"
(cd "$SELECTION_REPO" && git init -q . && git config user.email t@t && git config user.name t \
    && echo stable > tracked.txt && git add tracked.txt && git commit -qm init)
SELECTION_HEAD=$(git -C "$SELECTION_REPO" rev-parse HEAD)
SELECTION_CONTEXT_BASE="$TEST_OUTPUT_DIR/selection-context-base.json"
SELECTION_CONTEXT_TMP="$TEST_OUTPUT_DIR/selection-context.tmp.json"
SELECTION_SOURCE_BASE="$TEST_OUTPUT_DIR/selection-source-base.json"
cp "$AUTHORIZED_DIR/analysis-context.json" "$SELECTION_CONTEXT_BASE"
cp "$AUTHORIZED_DIR/pr-summary.json" "$SELECTION_REPORT/pr-summary.json"
cp "$NO_CODE_CONFIRMED_SOURCE" "$SELECTION_SOURCE_BASE"
SELECTION_WORKSPACE_FINGERPRINT=$(cd "$SELECTION_REPO" && \
    "$GH_PR_ENRICH" --test-call \
        code_access_workspace_fingerprint "$SELECTION_REPORT")
jq --arg inspected_sha "$SELECTION_HEAD" --arg workspace_fingerprint "$SELECTION_WORKSPACE_FINGERPRINT" '
    del(.coverage.context_fingerprint)
    | .coverage.code_access.state = "enabled"
    | .coverage.code_access.reason = "explicit fixture override"
    | .coverage.code_access.inspected_sha = $inspected_sha
    | .coverage.code_access.revision_matches = false
    | .coverage.code_access.workspace_fingerprint = $workspace_fingerprint
' "$SELECTION_CONTEXT_BASE" > "$SELECTION_CONTEXT_TMP"
SELECTION_CONTEXT_FINGERPRINT=$(
    "$GH_PR_ENRICH" --test-call analysis_context_fingerprint "$SELECTION_CONTEXT_TMP"
)
jq --arg fingerprint "$SELECTION_CONTEXT_FINGERPRINT" \
    '.coverage.context_fingerprint = $fingerprint' \
    "$SELECTION_CONTEXT_TMP" > "$SELECTION_REPORT/analysis-context.json"
jq --arg fingerprint "$SELECTION_CONTEXT_FINGERPRINT" \
    --arg workspace_fingerprint "$SELECTION_WORKSPACE_FINGERPRINT" \
    '._metadata.context_fingerprint = $fingerprint
     | ._metadata.workspace_fingerprint = $workspace_fingerprint' \
    "$SELECTION_SOURCE_BASE" > "$SELECTION_REPORT/hybrid-analysis.json"
MISSING_NATIVE_FINGERPRINT="$SELECTION_REPORT/missing-workspace-fingerprint.json"
jq 'del(._metadata.workspace_fingerprint)' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$MISSING_NATIVE_FINGERPRINT"
rc=0
(cd "$SELECTION_REPO" && \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$MISSING_NATIVE_FINGERPRINT" >/dev/null 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "confirmed native analysis without the snapshot fingerprint is rejected"
rm -f "$MISSING_NATIVE_FINGERPRINT"
(cd "$SELECTION_REPO" && \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" >/dev/null)
assert_jq "$SELECTION_REPORT/analysis.json" \
    'any(.issue_categories[]; .verdict == "confirmed")' \
    "a captured code-access grant persists without replaying its original override"
assert_jq_eq "$SELECTION_REPORT/analysis.json" \
    '._metadata.workspace_fingerprint' "$SELECTION_WORKSPACE_FINGERPRINT" \
    "confirmed native analysis binds the materialized workspace fingerprint"

rc=0
CODE_ACCESS_VETO_OUT=$(cd "$SELECTION_REPO" && GH_PR_ENRICH_CODE_ACCESS=false \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a current explicit code-access opt-out vetoes the captured grant"
assert_contains "$CODE_ACCESS_VETO_OUT" "revoked by --no-code-access" \
    "the current opt-out failure identifies the revocation"

echo changed-after-analysis >> "$SELECTION_REPO/tracked.txt"
rc=0
LOCAL_CODE_MISMATCH_OUT=$(cd "$SELECTION_REPO" && \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects confirmed findings after the local workspace changes"
assert_contains "$LOCAL_CODE_MISMATCH_OUT" "Current local code access no longer matches" \
    "the provider-neutral selection error identifies the stale local workspace"

chmod 555 "$SELECTION_REPORT"
READ_ONLY_SELECTED=$(cd "$SELECTION_REPO" && "$GH_PR_ENRICH" --test-call \
    select_analysis_file "$SELECTION_REPORT")
assert_true "$([ "$READ_ONLY_SELECTED" != "$SELECTION_REPORT/analysis.json" ] && \
    [ -f "$READ_ONLY_SELECTED" ] && cmp -s "$READ_ONLY_SELECTED" \
        "$SELECTION_REPORT/analysis.json" && echo 0 || echo 1)" \
    "read-only consumers receive a frozen historical analysis from an immutable archive"
assert_true "$([ -e "$SELECTION_REPORT/analysis.json" ] && echo 0 || echo 1)" \
    "read-only selection does not delete historical analysis"
READ_ONLY_SNAPSHOT_ROOT=$(dirname "$(dirname "$READ_ONLY_SELECTED")")
"$GH_PR_ENRICH" cleanup-analysis-snapshot "$READ_ONLY_SNAPSHOT_ROOT"
assert_true "$([ ! -e "$READ_ONLY_SNAPSHOT_ROOT" ] && echo 0 || echo 1)" \
    "read-only consumer explicitly cleans its private analysis snapshot"
chmod 755 "$SELECTION_REPORT"

rc=0
(cd "$SELECTION_REPO" && "$GH_PR_ENRICH" --test-call \
    select_analysis_file "$SELECTION_REPORT" require-current-workspace \
    >/dev/null 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "strict consumers reject selected analysis after the workspace changes"
assert_true "$([ ! -e "$SELECTION_REPORT/analysis.json" ] && echo 0 || echo 1)" \
    "strict workspace rejection invalidates stale selected artifacts"

rc=0
echo "do not overwrite" > "$TEST_OUTPUT_DIR/selection-temp-target.json"
ln -s "$TEST_OUTPUT_DIR/selection-temp-target.json" \
    "$AUTHORIZED_DIR/combined-data.tmp.json"
HOSTED_HEAD_OUT=$(PR_HEAD_OID="new-hosted-head" "$GH_PR_ENRICH" select-analysis \
    "$AUTHORIZED_DIR" "$HYBRID_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects a result after the hosted PR head advances"
assert_contains "$HOSTED_HEAD_OUT" "Hosted PR head changed" \
    "the selection error identifies the hosted revision race"
assert_true "$([ ! -e "$AUTHORIZED_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "a hosted revision race invalidates the stale selected artifact"
assert_eq "do not overwrite" "$(cat "$TEST_OUTPUT_DIR/selection-temp-target.json")" \
    "selection invalidation never follows a planted fixed-name temp symlink"
rm "$AUTHORIZED_DIR/combined-data.tmp.json"
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$HYBRID_SOURCE" >/dev/null

FORGED_IDENTITY_SOURCE="$AUTHORIZED_DIR/forged-identity-analysis.json"
jq '._metadata.repository = "attacker/shadow" | ._metadata.pr_number = 999' \
    "$HYBRID_SOURCE" > "$FORGED_IDENTITY_SOURCE"
rc=0
FORGED_IDENTITY_OUT=$("$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" \
    "$FORGED_IDENTITY_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "candidate metadata cannot redirect hosted-head verification to another PR"
assert_contains "$FORGED_IDENTITY_OUT" "fingerprinted context" \
    "identity redirection is rejected against the captured context"

MISMATCH_SOURCE="$AUTHORIZED_DIR/mismatched-analysis.json"
jq '._metadata.pr_head_sha = "wrong-head"' "$HYBRID_SOURCE" > "$MISMATCH_SOURCE"
rc=0
MISMATCH_OUT=$("$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$MISMATCH_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects a result for a different PR head"
assert_contains "$MISMATCH_OUT" "PR head" \
    "the selection error names the revision mismatch"

INCOMPLETE_SOURCE="$AUTHORIZED_DIR/incomplete-analysis.json"
jq 'del(.systemic_issues)' "$HYBRID_SOURCE" > "$INCOMPLETE_SOURCE"
SELECTED_BEFORE=$(jq -c . "$AUTHORIZED_DIR/analysis.json")
REPORT_BEFORE=$(cat "$AUTHORIZED_DIR/analysis.md")
rc=0
INCOMPLETE_OUT=$("$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$INCOMPLETE_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects a same-head source missing a required analysis section"
assert_contains "$INCOMPLETE_OUT" "missing required" \
    "the incomplete-analysis error names the contract failure"
assert_eq "$SELECTED_BEFORE" "$(jq -c . "$AUTHORIZED_DIR/analysis.json")" \
    "a rejected selection preserves the prior selected JSON"
assert_eq "$REPORT_BEFORE" "$(cat "$AUTHORIZED_DIR/analysis.md")" \
    "a rejected selection preserves the prior selected Markdown"

MALFORMED_SOURCE="$AUTHORIZED_DIR/malformed-analysis.json"
jq '.task_list = [{priority: {not: "a string"}}]' "$HYBRID_SOURCE" > "$MALFORMED_SOURCE"
rc=0
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$MALFORMED_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects malformed nested finding fields"
assert_eq "$SELECTED_BEFORE" "$(jq -c . "$AUTHORIZED_DIR/analysis.json")" \
    "a malformed nested finding does not replace selected JSON"
assert_eq "$REPORT_BEFORE" "$(cat "$AUTHORIZED_DIR/analysis.md")" \
    "a malformed nested finding does not replace selected Markdown"

UNATTRIBUTED_SOURCE="$AUTHORIZED_DIR/unattributed-hybrid.json"
jq '.issue_categories = [{
        name: "Unattributed finding", category: "logic_error", severity: "high",
        impact: "moderate", likelihood: "likely", severity_rationale: "fixture",
        verdict: "confirmed", confidence: "high", description: "fixture",
        evidence: [{file: "gh-pr-enrich", line: 1, detail: "fixture"}], thread_ids: []
    }]' "$HYBRID_SOURCE" > "$UNATTRIBUTED_SOURCE"
rc=0
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$UNATTRIBUTED_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "hybrid findings require per-finding analyzer attribution"
assert_eq "$SELECTED_BEFORE" "$(jq -c . "$AUTHORIZED_DIR/analysis.json")" \
    "an unattributed hybrid finding does not replace selected JSON"

INVALID_PROVIDER_SOURCE="$AUTHORIZED_DIR/invalid-provider.json"
jq '._metadata.provider = "unknown-provider"' "$HYBRID_SOURCE" > "$INVALID_PROVIDER_SOURCE"
rc=0
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$INVALID_PROVIDER_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects unknown provider provenance"

NO_EVIDENCE_SOURCE="$AUTHORIZED_DIR/no-evidence.json"
jq '.issue_categories = [{
        name: "No anchor", category: "boundary_condition", severity: "high",
        impact: "moderate", likelihood: "likely", severity_rationale: "fixture",
        verdict: "confirmed", confidence: "high", description: "fixture",
        evidence: [], thread_ids: [], sources: ["codex:orchestrator"]
    }]
    | .category_coverage |= map(if .category == "boundary_condition"
        then .verdict = "findings_reported" else . end)' \
    "$HYBRID_SOURCE" > "$NO_EVIDENCE_SOURCE"
rc=0
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$NO_EVIDENCE_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects evidence-free findings"

CONTRADICTORY_SOURCE="$AUTHORIZED_DIR/contradictory-coverage.json"
jq '.issue_categories = [{
        name: "Anchored", category: "boundary_condition", severity: "high",
        impact: "moderate", likelihood: "likely", severity_rationale: "fixture",
        verdict: "confirmed", confidence: "high", description: "fixture",
        evidence: [{file:"a.js",line:1,detail:"fixture"}], thread_ids: [],
        sources: ["codex:orchestrator"]
    }]' "$HYBRID_SOURCE" > "$CONTRADICTORY_SOURCE"
rc=0
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$CONTRADICTORY_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects findings contradicted by reviewed-none coverage"

SWAPPED_ROLES_SOURCE="$AUTHORIZED_DIR/swapped-roles.json"
jq '._metadata.analyzers = [
        {provider:"codex",role:"external"},
        {provider:"claude",role:"orchestrator"}
    ]' "$HYBRID_SOURCE" > "$SWAPPED_ROLES_SOURCE"
rc=0
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$SWAPPED_ROLES_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "hybrid provenance rejects swapped orchestrator and external roles"

MISLABELED_CODEX_SOURCE="$AUTHORIZED_DIR/mislabeled-codex.json"
jq '._metadata.provider = "codex"
    | ._metadata.analyzers = [
        {provider:"codex",role:"orchestrator"},
        {provider:"claude",role:"external"}
    ]' "$HYBRID_SOURCE" > "$MISLABELED_CODEX_SOURCE"
rc=0
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$MISLABELED_CODEX_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a Codex label cannot conceal an external Claude analyzer"

FRACTIONAL_LINE_SOURCE="$AUTHORIZED_DIR/fractional-lines.json"
jq '.task_list[0].line = 1.5' "$HYBRID_SOURCE" > "$FRACTIONAL_LINE_SOURCE"
rc=0
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$FRACTIONAL_LINE_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selector line validation matches the schema integer contract"

INVENTED_SOURCE_ID="$AUTHORIZED_DIR/invented-source-id.json"
jq '.issue_categories = [{
        name: "Invented source", category: "boundary_condition", severity: "high",
        impact: "moderate", likelihood: "likely", severity_rationale: "fixture",
        verdict: "confirmed", confidence: "high", description: "fixture",
        evidence: [{file:"a.js",line:1,detail:"fixture"}], thread_ids: [],
        sources: ["codex:invented"]
    }]
    | .category_coverage |= map(if .category == "boundary_condition"
        then .verdict = "findings_reported" else . end)' \
    "$HYBRID_SOURCE" > "$INVENTED_SOURCE_ID"
rc=0
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$INVENTED_SOURCE_ID" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "hybrid finding sources must map to a declared analyzer identity"

# Failed required GitHub sources are part of the snapshot and prevent a clean
# selected verdict even when an analyzer otherwise returns every category.
cp "$AUTHORIZED_DIR/analysis-context.json" "$AUTHORIZED_DIR/context-before-source-failure.json"
jq '.coverage.sources.issue_comments = {requested:true,status:"failed",reason:"fixture"}' \
    "$AUTHORIZED_DIR/analysis-context.json" > "$AUTHORIZED_DIR/source-failed-context.tmp.json"
FAILED_SOURCE_FINGERPRINT=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
    "$AUTHORIZED_DIR/source-failed-context.tmp.json")
jq --arg fingerprint "$FAILED_SOURCE_FINGERPRINT" '.coverage.context_fingerprint = $fingerprint' \
    "$AUTHORIZED_DIR/source-failed-context.tmp.json" > "$AUTHORIZED_DIR/analysis-context.json"
jq --arg fingerprint "$FAILED_SOURCE_FINGERPRINT" \
    '._metadata.context_fingerprint = $fingerprint' "$HYBRID_SOURCE" > "$AUTHORIZED_DIR/source-failed-analysis.json"
rc=0
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$AUTHORIZED_DIR/source-failed-analysis.json" \
    >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "failed required GitHub inputs prevent publishing a clean selected result"

jq 'del(.coverage.sources)' "$AUTHORIZED_DIR/context-before-source-failure.json" \
    > "$AUTHORIZED_DIR/missing-sources-context.tmp.json"
MISSING_SOURCES_FINGERPRINT=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
    "$AUTHORIZED_DIR/missing-sources-context.tmp.json")
jq --arg fingerprint "$MISSING_SOURCES_FINGERPRINT" '.coverage.context_fingerprint = $fingerprint' \
    "$AUTHORIZED_DIR/missing-sources-context.tmp.json" > "$AUTHORIZED_DIR/analysis-context.json"
jq --arg fingerprint "$MISSING_SOURCES_FINGERPRINT" \
    '._metadata.context_fingerprint = $fingerprint' "$HYBRID_SOURCE" > "$AUTHORIZED_DIR/missing-sources-analysis.json"
rc=0
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$AUTHORIZED_DIR/missing-sources-analysis.json" \
    >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "missing GitHub source coverage cannot pass selection vacuously"
mv "$AUTHORIZED_DIR/context-before-source-failure.json" "$AUTHORIZED_DIR/analysis-context.json"

# Known omissions cannot be promoted as clean category coverage. The context
# does not attribute omitted bytes to individual categories, so every category
# without a finding must remain explicitly not_reviewable.
TRUNCATION_CASE_ROOT="$TEST_OUTPUT_DIR/truncated-selection"
mkdir -p "$TRUNCATION_CASE_ROOT"
for TRUNCATION_CASE in pr_body issue review inline thread_body thread_replies diff commit linked_issue; do
    TRUNCATION_CASE_DIR="$TRUNCATION_CASE_ROOT/$TRUNCATION_CASE"
    mkdir -p "$TRUNCATION_CASE_DIR"
    cp "$AUTHORIZED_DIR/pr-summary.json" "$TRUNCATION_CASE_DIR/pr-summary.json"
    cp "$AUTHORIZED_DIR/analysis.json" "$TRUNCATION_CASE_DIR/analysis.json"
    cp "$AUTHORIZED_DIR/analysis.md" "$TRUNCATION_CASE_DIR/analysis.md"
    cp "$AUTHORIZED_DIR/context-coverage.md" "$TRUNCATION_CASE_DIR/context-coverage.md"
    cp "$AUTHORIZED_DIR/combined-data.json" "$TRUNCATION_CASE_DIR/combined-data.json"
    cp "$AUTHORIZED_DIR/comprehensive-report.md" \
        "$TRUNCATION_CASE_DIR/comprehensive-report.md"
    case "$TRUNCATION_CASE" in
        pr_body) TRUNCATION_FILTER='.coverage.pr_description.truncated = ["PR description"]' ;;
        issue) TRUNCATION_FILTER='.coverage.issue_comments.truncated = ["issue-u"]' ;;
        review) TRUNCATION_FILTER='.coverage.review_comments.truncated = ["review-u"]' ;;
        inline) TRUNCATION_FILTER='.coverage.inline_comments.truncated = ["inline-u"]' ;;
        thread_body) TRUNCATION_FILTER='.coverage.unresolved_threads.truncated = ["thread-u"]' ;;
        thread_replies) TRUNCATION_FILTER='.coverage.unresolved_threads.incomplete_comment_threads = ["PRRT_more"]' ;;
        diff) TRUNCATION_FILTER='.coverage.diff.files_truncated = ["a.js"]' ;;
        commit) TRUNCATION_FILTER='.coverage.commits.truncated = ["abc1234"]' ;;
        linked_issue) TRUNCATION_FILTER='.coverage.linked_issues.truncated = ["issue-u"]' ;;
    esac
    jq "del(.coverage.context_fingerprint) | $TRUNCATION_FILTER" \
        "$AUTHORIZED_DIR/analysis-context.json" \
        > "$TRUNCATION_CASE_DIR/context.tmp.json"
    TRUNCATION_FINGERPRINT=$(
        "$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
            "$TRUNCATION_CASE_DIR/context.tmp.json"
    )
    jq --arg fingerprint "$TRUNCATION_FINGERPRINT" \
        '.coverage.context_fingerprint = $fingerprint' \
        "$TRUNCATION_CASE_DIR/context.tmp.json" \
        > "$TRUNCATION_CASE_DIR/analysis-context.json"
    jq --arg fingerprint "$TRUNCATION_FINGERPRINT" \
        '._metadata.context_fingerprint = $fingerprint' \
        "$HYBRID_SOURCE" > "$TRUNCATION_CASE_DIR/candidate.json"
    cp "$TRUNCATION_CASE_DIR/analysis.json" \
        "$TRUNCATION_CASE_DIR/analysis.before.json"
    rc=0
    TRUNCATION_OUT=$("$GH_PR_ENRICH" select-analysis \
        "$TRUNCATION_CASE_DIR" "$TRUNCATION_CASE_DIR/candidate.json" 2>&1) || rc=$?
    assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
        "$TRUNCATION_CASE truncation rejects clean category verdicts"
    assert_contains "$TRUNCATION_OUT" "analysis inputs require" \
        "$TRUNCATION_CASE rejection identifies the incomplete-evidence contract"
    assert_true "$(cmp -s "$TRUNCATION_CASE_DIR/analysis.json" \
        "$TRUNCATION_CASE_DIR/analysis.before.json"; echo $?)" \
        "$TRUNCATION_CASE rejection preserves the prior selected artifact"
done

NO_CODE_OR_DIFF_DIR="$TEST_OUTPUT_DIR/no-code-or-diff-selection"
mkdir -p "$NO_CODE_OR_DIFF_DIR"
cp "$AUTHORIZED_DIR/pr-summary.json" "$NO_CODE_OR_DIFF_DIR/pr-summary.json"
jq 'del(.coverage.context_fingerprint)
    | .coverage.code_access.state = "disabled"
    | .coverage.diff.included = false
    | .coverage.diff.requested = false
    | .coverage.diff.status = "not_requested"
    | .coverage.diff.files_truncated = []' \
    "$AUTHORIZED_DIR/analysis-context.json" \
    > "$NO_CODE_OR_DIFF_DIR/context.tmp.json"
NO_CODE_OR_DIFF_FINGERPRINT=$(
    "$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
        "$NO_CODE_OR_DIFF_DIR/context.tmp.json"
)
jq --arg fingerprint "$NO_CODE_OR_DIFF_FINGERPRINT" \
    '.coverage.context_fingerprint = $fingerprint' \
    "$NO_CODE_OR_DIFF_DIR/context.tmp.json" \
    > "$NO_CODE_OR_DIFF_DIR/analysis-context.json"
jq --arg fingerprint "$NO_CODE_OR_DIFF_FINGERPRINT" \
    '._metadata.context_fingerprint = $fingerprint' \
    "$HYBRID_SOURCE" > "$NO_CODE_OR_DIFF_DIR/candidate.json"
rc=0
NO_CODE_OR_DIFF_OUT=$("$GH_PR_ENRICH" select-analysis \
    "$NO_CODE_OR_DIFF_DIR" "$NO_CODE_OR_DIFF_DIR/candidate.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "clean category verdicts require either repository code access or an included diff"
assert_contains "$NO_CODE_OR_DIFF_OUT" "Incomplete or truncated analysis inputs" \
    "the no-code/no-diff rejection identifies the missing-evidence contract"
jq '.category_coverage |= map(.verdict = "not_reviewable")' \
    "$NO_CODE_OR_DIFF_DIR/candidate.json" \
    > "$NO_CODE_OR_DIFF_DIR/not-reviewable.json"
"$GH_PR_ENRICH" select-analysis "$NO_CODE_OR_DIFF_DIR" \
    "$NO_CODE_OR_DIFF_DIR/not-reviewable.json" >/dev/null
assert_jq "$NO_CODE_OR_DIFF_DIR/analysis.json" \
    'all(.category_coverage[]; .verdict == "not_reviewable")' \
    "a no-code/no-diff analysis remains selectable when it reports every gap"

PARTIAL_DIFF_DIR="$TEST_OUTPUT_DIR/partial-diff-selection"
mkdir -p "$PARTIAL_DIFF_DIR"
cp "$AUTHORIZED_DIR/pr-summary.json" "$PARTIAL_DIFF_DIR/pr-summary.json"
jq 'del(.coverage.context_fingerprint)
    | .coverage.code_access.state = "disabled"
    | .coverage.diff.included = true
    | .coverage.diff.requested = true
    | .coverage.diff.status = "partial"
    | .coverage.diff.files_included = 1
    | .coverage.diff.files_total = 1
    | .coverage.diff.files_truncated = []' \
    "$AUTHORIZED_DIR/analysis-context.json" \
    > "$PARTIAL_DIFF_DIR/context.tmp.json"
PARTIAL_DIFF_FINGERPRINT=$(
    "$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
        "$PARTIAL_DIFF_DIR/context.tmp.json"
)
jq --arg fingerprint "$PARTIAL_DIFF_FINGERPRINT" \
    '.coverage.context_fingerprint = $fingerprint' \
    "$PARTIAL_DIFF_DIR/context.tmp.json" \
    > "$PARTIAL_DIFF_DIR/analysis-context.json"
jq --arg fingerprint "$PARTIAL_DIFF_FINGERPRINT" \
    '._metadata.context_fingerprint = $fingerprint' \
    "$HYBRID_SOURCE" > "$PARTIAL_DIFF_DIR/candidate.json"
rc=0
PARTIAL_DIFF_OUT=$("$GH_PR_ENRICH" select-analysis \
    "$PARTIAL_DIFF_DIR" "$PARTIAL_DIFF_DIR/candidate.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a partial diff cannot certify clean categories without repository code access"
assert_contains "$PARTIAL_DIFF_OUT" "Incomplete or truncated analysis inputs" \
    "the partial-diff rejection identifies the missing-evidence contract"

TRUNCATION_POSITIVE_DIR="$TRUNCATION_CASE_ROOT/explicit-not-reviewable"
cp -R "$TRUNCATION_CASE_ROOT/linked_issue" "$TRUNCATION_POSITIVE_DIR"
rm -f "$TRUNCATION_POSITIVE_DIR/.selected-analysis-"* \
    "$TRUNCATION_POSITIVE_DIR/analysis.before.json"
jq '.category_coverage |= map(.verdict = "not_reviewable")' \
    "$TRUNCATION_POSITIVE_DIR/candidate.json" \
    > "$TRUNCATION_POSITIVE_DIR/not-reviewable.json"
"$GH_PR_ENRICH" select-analysis "$TRUNCATION_POSITIVE_DIR" \
    "$TRUNCATION_POSITIVE_DIR/not-reviewable.json" >/dev/null
assert_jq "$TRUNCATION_POSITIVE_DIR/analysis.json" \
    'all(.category_coverage[]; .verdict == "not_reviewable")' \
    "explicit not_reviewable coverage can be selected with truncated evidence"

jq '.issue_categories = [{
        name:"Visible defect",category:"logic_error",severity:"high",
        impact:"moderate",likelihood:"likely",severity_rationale:"fixture",
        verdict:"plausible",confidence:"medium",description:"fixture",
        evidence:[{file:"a.js",line:1,detail:"fixture"}],thread_ids:[],
        sources:["codex:orchestrator"]
    }]
    | .category_coverage |= map(
        if .category == "logic_error" then .verdict = "findings_reported"
        else .verdict = "not_reviewable" end)' \
    "$TRUNCATION_POSITIVE_DIR/candidate.json" \
    > "$TRUNCATION_POSITIVE_DIR/mixed.json"
"$GH_PR_ENRICH" select-analysis "$TRUNCATION_POSITIVE_DIR" \
    "$TRUNCATION_POSITIVE_DIR/mixed.json" >/dev/null
assert_jq "$TRUNCATION_POSITIVE_DIR/analysis.json" \
    '(.category_coverage[] | select(.category == "logic_error").verdict) == "findings_reported" and
     all(.category_coverage[]; .category == "logic_error" or .verdict == "not_reviewable")' \
    "findings remain selectable when every omitted clean axis is not_reviewable"

# A current Claude provider source is not a legacy fallback when selection has
# rejected or omitted analysis.json.
CURRENT_REJECTED_DIR="$TEST_OUTPUT_DIR/current-rejected"
mkdir -p "$CURRENT_REJECTED_DIR"
cp "$AUTHORIZED_DIR/analysis-context.json" "$CURRENT_REJECTED_DIR/analysis-context.json"
cp "$AUTHORIZED_DIR/claude-analysis.json" "$CURRENT_REJECTED_DIR/claude-analysis.json"
rc=0
"$GH_PR_ENRICH" --test-call select_analysis_file "$CURRENT_REJECTED_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a current rejected Claude source cannot bypass selection as a legacy fallback"

LEGACY_WITH_CONTEXT_DIR="$TEST_OUTPUT_DIR/legacy-with-current-context"
mkdir -p "$LEGACY_WITH_CONTEXT_DIR"
cp "$AUTHORIZED_DIR/analysis-context.json" "$LEGACY_WITH_CONTEXT_DIR/analysis-context.json"
jq 'del(._metadata)' "$AUTHORIZED_DIR/claude-analysis.json" \
    > "$LEGACY_WITH_CONTEXT_DIR/claude-analysis.json"
rc=0
"$GH_PR_ENRICH" --test-call select_analysis_file "$LEGACY_WITH_CONTEXT_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "metadata-less legacy fallback is rejected beside a current analysis context"

LEGACY_READ_ONLY_DIR="$TEST_OUTPUT_DIR/legacy-read-only"
mkdir -p "$LEGACY_READ_ONLY_DIR"
jq 'del(._metadata)' "$AUTHORIZED_DIR/claude-analysis.json" \
    > "$LEGACY_READ_ONLY_DIR/claude-analysis.json"
chmod 555 "$LEGACY_READ_ONLY_DIR"
rc=0
LEGACY_READ_ONLY_SELECTED=$("$GH_PR_ENRICH" --test-call \
    select_analysis_file "$LEGACY_READ_ONLY_DIR" 2>/dev/null) || rc=$?
assert_true "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" \
    "read-only discovery retains metadata-less legacy reports in immutable archives"
assert_true "$([ -f "$LEGACY_READ_ONLY_SELECTED" ] && \
    [ "$LEGACY_READ_ONLY_SELECTED" != \
      "$LEGACY_READ_ONLY_DIR/claude-analysis.json" ] && echo 0 || echo 1)" \
    "legacy read-only discovery returns a private frozen report"
LEGACY_SNAPSHOT_ROOT=$(dirname "$(dirname "$LEGACY_READ_ONLY_SELECTED")")
"$GH_PR_ENRICH" cleanup-analysis-snapshot "$LEGACY_SNAPSHOT_ROOT"
chmod 755 "$LEGACY_READ_ONLY_DIR"
rc=0
"$GH_PR_ENRICH" --test-call select_analysis_file "$LEGACY_READ_ONLY_DIR" \
    require-current-workspace >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "strict consumers reject legacy reports without current provenance"

cp "$AUTHORIZED_DIR/pr-summary.json" "$AUTHORIZED_DIR/pr-summary-before-head-refresh.json"
jq '.headRefOid = "new-hosted-head"' "$AUTHORIZED_DIR/pr-summary.json" \
    > "$AUTHORIZED_DIR/pr-summary.tmp.json"
mv "$AUTHORIZED_DIR/pr-summary.tmp.json" "$AUTHORIZED_DIR/pr-summary.json"
rc=0
"$GH_PR_ENRICH" --test-call select_analysis_file "$AUTHORIZED_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a freshly fetched PR summary head invalidates stale context and analysis"
mv "$AUTHORIZED_DIR/pr-summary-before-head-refresh.json" "$AUTHORIZED_DIR/pr-summary.json"

# A same-head context refresh (for example, new review comments) changes the
# fingerprint and invalidates a previously selected result.
jq '.issue_comments += [{user:"reviewer",body:"tampered",url:"u",created_at:"t"}]' \
    "$AUTHORIZED_DIR/analysis-context.json" > "$AUTHORIZED_DIR/tampered-context.tmp.json"
mv "$AUTHORIZED_DIR/tampered-context.tmp.json" "$AUTHORIZED_DIR/analysis-context.json"
rc=0
"$GH_PR_ENRICH" --test-call select_analysis_file "$AUTHORIZED_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "consumers recompute the fingerprint and reject context mutation without a refresh"

jq 'del(.coverage.context_fingerprint) | .issue_comments += [{user:"reviewer",body:"new",url:"u",created_at:"t"}]' \
    "$AUTHORIZED_DIR/analysis-context.json" > "$AUTHORIZED_DIR/refreshed-context.tmp.json"
NEW_FINGERPRINT=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
    "$AUTHORIZED_DIR/refreshed-context.tmp.json")
jq --arg fingerprint "$NEW_FINGERPRINT" '.coverage.context_fingerprint = $fingerprint' \
    "$AUTHORIZED_DIR/refreshed-context.tmp.json" > "$AUTHORIZED_DIR/analysis-context.json"
rc=0
"$GH_PR_ENRICH" --test-call select_analysis_file "$AUTHORIZED_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "same-head context refreshes invalidate stale selected analysis"

jq '.coverage.code_access.pr_head_sha = "new-head"' \
    "$AUTHORIZED_DIR/analysis-context.json" > "$AUTHORIZED_DIR/analysis-context.tmp.json"
mv "$AUTHORIZED_DIR/analysis-context.tmp.json" "$AUTHORIZED_DIR/analysis-context.json"
rc=0
"$GH_PR_ENRICH" --test-call select_analysis_file "$AUTHORIZED_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "consumers reject selected analysis after the report context moves to a new PR head"

suite_end
