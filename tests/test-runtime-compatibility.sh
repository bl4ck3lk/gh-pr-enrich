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
TMP_ALIAS_SELECTION="/tmp/gh-pr-enrich-selection-$$"
RUNTIME_BACKGROUND_PID=""
COLLECTION_LOCK_RELEASE=""
COLLECTION_ACQUIRE_RELEASE=""
COLLECTION_SIGNAL_RM_RELEASE=""
LINKED_CONCURRENT_RELEASE=""
CHILD_START_PID_FILE=""
REPORT_WATCHDOG_CHILD_PID_FILE=""
REPORT_WATCHDOG_PID_FILE=""
VISIBILITY_SIGNAL_CHILD_PID_FILE=""
VISIBILITY_SIGNAL_WATCHDOG_PID_FILE=""
BLOCKED_HEAD_CHILD_PID_FILE=""
BLOCKED_HEAD_DESCENDANT_PID_FILE=""
PROVIDER_SIGNAL_CHILD_PID_FILE=""
PROVIDER_SIGNAL_DESCENDANT_PID_FILE=""

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
        for (( _cleanup_attempt=0; _cleanup_attempt < 40; _cleanup_attempt++ )); do
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
    for cleanup_pid_file in "$REPORT_WATCHDOG_CHILD_PID_FILE" \
            "$REPORT_WATCHDOG_PID_FILE" \
            "$VISIBILITY_SIGNAL_CHILD_PID_FILE" \
            "$VISIBILITY_SIGNAL_WATCHDOG_PID_FILE"; do
        [ -n "$cleanup_pid_file" ] && [ -f "$cleanup_pid_file" ] || continue
        cleanup_child_pid=$(cat "$cleanup_pid_file" 2>/dev/null || echo "")
        if [ -n "$cleanup_child_pid" ] && \
           kill -0 "$cleanup_child_pid" 2>/dev/null; then
            kill -KILL "$cleanup_child_pid" 2>/dev/null || true
        fi
    done
    for cleanup_pid_file in "$BLOCKED_HEAD_CHILD_PID_FILE" \
            "$BLOCKED_HEAD_DESCENDANT_PID_FILE" \
            "$PROVIDER_SIGNAL_CHILD_PID_FILE" \
            "$PROVIDER_SIGNAL_DESCENDANT_PID_FILE" \
            "${PRELOCK_HEAD_CHILD_PID:-}" \
            "${PRELOCK_HEAD_DESCENDANT_PID:-}"; do
        [ -n "$cleanup_pid_file" ] && [ -f "$cleanup_pid_file" ] || continue
        cleanup_child_pid=$(cat "$cleanup_pid_file" 2>/dev/null || echo "")
        if [ -n "$cleanup_child_pid" ] && \
           kill -0 "$cleanup_child_pid" 2>/dev/null; then
            kill -KILL "$cleanup_child_pid" 2>/dev/null || true
        fi
    done
    rm -rf "$TEST_OUTPUT_DIR" "$TMP_ALIAS_OUTPUT" "$TMP_ALIAS_SELECTION"
}
trap cleanup EXIT
cleanup
mkdir -p "$STUB_DIR"

# End-to-end fixtures use immediate GitHub command stubs, but each managed
# request still waits for the production 200 ms watchdog poll. Compress only
# that poll in this test process so timeout state transitions and iteration
# counts remain unchanged without adding minutes of idle wall time to the suite.
cat > "$STUB_DIR/sleep" << 'STUB'
#!/bin/bash
if [ "${GH_PR_ENRICH_TEST_REAL_GITHUB_SLEEP:-false}" != true ]; then
    case "${1:-}" in
        0.05) exec /bin/sleep 0.005 ;;
        0.2) exec /bin/sleep 0.01 ;;
        1) exec /bin/sleep 0.02 ;;
    esac
fi
exec /bin/sleep "$@"
STUB
chmod +x "$STUB_DIR/sleep"

suite_start "gh pr-enrich runtime compatibility suite"

assert_no_selection_transaction_residue() {
    local report_dir="$1"
    local description="$2"
    local residue
    residue=$(find "$report_dir" -maxdepth 1 \
        \( -name '.selected-analysis.lock' -o \
           -name '.selected-analysis-replacements.*' -o \
           -name '.selected-analysis-quarantine.*' -o \
           -name '.selected-analysis-release.*' -o \
           -name '.selected-analysis-stale.*' \) -print -quit)
    assert_true "$([ -z "$residue" ] && echo 0 || echo 1)" "$description" \
        "residue: ${residue:-none}"
}

assert_selection_views_match() {
    local report_dir="$1"
    local backup_dir="$2"
    local description="$3"
    local view matches=true
    for view in analysis.json analysis.md context-coverage.md \
            combined-data.json comprehensive-report.md; do
        if [ -f "$backup_dir/$view" ]; then
            cmp -s "$report_dir/$view" "$backup_dir/$view" || matches=false
        elif [ -e "$report_dir/$view" ]; then
            matches=false
        fi
    done
    assert_true "$([ "$matches" = true ] && echo 0 || echo 1)" "$description"
}

assert_process_reaped() {
    local pid="$1" description="$2" reaped=true
    if [ -n "$pid" ]; then
        for (( _wait_attempt=0; _wait_attempt < 40; _wait_attempt++ )); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.01
        done
    fi
    if [ -z "$pid" ] || kill -0 "$pid" 2>/dev/null; then
        reaped=false
        [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
    fi
    assert_true "$([ "$reaped" = true ] && echo 0 || echo 1)" "$description"
}

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
assert_not_contains "$(cat "$GH_PR_ENRICH")" '$(seq ' \
    "shipped wait loops do not require non-stock seq on macOS"

# ---------------------------------------------------------------------------
# Skill installation
# ---------------------------------------------------------------------------
TEST_HOME="$TEST_OUTPUT_DIR/home"
mkdir -p "$TEST_HOME"

assert_no_skill_install_residue() {
    local description="$1" residue="" skills_dir candidate
    for skills_dir in "$TEST_HOME/.codex/skills" "$TEST_HOME/.claude/skills"; do
        for candidate in "$skills_dir"/.gh-pr-enrich-install.* \
            "$skills_dir"/.gh-pr-enrich-uninstall.*; do
            if [ -e "$candidate" ] || [ -L "$candidate" ]; then
                residue="$candidate"
                break 2
            fi
        done
    done
    assert_true "$([ -z "$residue" ] && echo 0 || echo 1)" "$description" \
        "residue: ${residue:-none}"
}

PLANTED_INSTALL_RESIDUE="$TEST_HOME/.codex/skills/.gh-pr-enrich-install.planted"
mkdir -p "$PLANTED_INSTALL_RESIDUE"
planted_residue_detected=false
for planted_candidate in "$TEST_HOME/.codex/skills"/.gh-pr-enrich-install.*; do
    [ "$planted_candidate" != "$PLANTED_INSTALL_RESIDUE" ] || \
        planted_residue_detected=true
done

assert_true "$([ "$planted_residue_detected" = true ] && echo 0 || echo 1)" \
    "the portable residue scan detects a planted transaction directory"
rmdir "$PLANTED_INSTALL_RESIDUE"

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

CONFIGURED_HOME="$TEST_OUTPUT_DIR/configured-home"
CONFIGURED_CODEX_ROOT="$TEST_OUTPUT_DIR/configured-codex"
CONFIGURED_CLAUDE_ROOT="$TEST_OUTPUT_DIR/configured-claude"
mkdir -p "$CONFIGURED_HOME"
env HOME="$CONFIGURED_HOME" CODEX_HOME="$CONFIGURED_CODEX_ROOT" \
    CLAUDE_CONFIG_DIR="$CONFIGURED_CLAUDE_ROOT" \
    "$GH_PR_ENRICH" install-skill >/dev/null
assert_true "$([ -L "$CONFIGURED_CODEX_ROOT/skills/gh-pr-enrich" ] && \
    [ -L "$CONFIGURED_CLAUDE_ROOT/skills/gh-pr-enrich" ] && echo 0 || echo 1)" \
    "the installer honors configured Codex and Claude homes"
assert_true "$([ ! -e "$CONFIGURED_HOME/.codex/skills/gh-pr-enrich" ] && \
    [ ! -e "$CONFIGURED_HOME/.claude/skills/gh-pr-enrich" ] && echo 0 || echo 1)" \
    "configured runtime homes do not publish fallback HOME registrations"
env HOME="$CONFIGURED_HOME" CODEX_HOME="$CONFIGURED_CODEX_ROOT" \
    CLAUDE_CONFIG_DIR="$CONFIGURED_CLAUDE_ROOT" \
    "$GH_PR_ENRICH" uninstall-skill >/dev/null
assert_true "$([ ! -e "$CONFIGURED_CODEX_ROOT/skills/gh-pr-enrich" ] && \
    [ ! -e "$CONFIGURED_CLAUDE_ROOT/skills/gh-pr-enrich" ] && echo 0 || echo 1)" \
    "the uninstaller honors configured Codex and Claude homes"

# A pending signal while validating an existing Codex registration must stop
# before the transaction publishes a missing Claude registration.
HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill --runtime codex >/dev/null
EXISTING_CODEX_SIGNAL_STUBS="$TEST_OUTPUT_DIR/existing-codex-signal-stubs"
mkdir -p "$EXISTING_CODEX_SIGNAL_STUBS"
cat > "$EXISTING_CODEX_SIGNAL_STUBS/mkdir" << 'STUB'
#!/bin/bash
target="${!#}"
/bin/mkdir "$@" || exit $?
if [ "$target" = "$SIGNAL_CODEX_SKILLS_DIR" ]; then
    kill -INT "$PPID"
fi
exit 0
STUB
chmod +x "$EXISTING_CODEX_SIGNAL_STUBS/mkdir"
rc=0
env HOME="$TEST_HOME" SIGNAL_CODEX_SKILLS_DIR="$TEST_HOME/.codex/skills" \
    PATH="$EXISTING_CODEX_SIGNAL_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill >/dev/null 2>&1 || rc=$?
assert_eq "130" "$rc" \
    "INT during existing-Codex validation preserves the conventional status"
assert_true "$([ -L "$CODEX_SKILL" ] && [ ! -L "$CLAUDE_SKILL" ] && echo 0 || echo 1)" \
    "existing-Codex cancellation performs no later Claude publication"
assert_no_skill_install_residue \
    "existing-Codex cancellation creates no private ownership reference"
HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill --runtime codex >/dev/null
assert_true "$([ ! -e "$CLAUDE_SKILL" ] && echo 0 || echo 1)" \
    "the uninstaller removes the Claude registration"
assert_true "$([ ! -e "$CODEX_SKILL" ] && echo 0 || echo 1)" \
    "the uninstaller removes the Codex registration"

# Dotfile-managed homes commonly symlink each runtime's skills directory.
SYMLINK_HOME="$TEST_OUTPUT_DIR/symlink-home"
mkdir -p "$SYMLINK_HOME/.codex" "$SYMLINK_HOME/.claude" \
    "$SYMLINK_HOME/real-codex-skills" "$SYMLINK_HOME/real-claude-skills"
ln -s "$SYMLINK_HOME/real-codex-skills" "$SYMLINK_HOME/.codex/skills"
ln -s "$SYMLINK_HOME/real-claude-skills" "$SYMLINK_HOME/.claude/skills"
HOME="$SYMLINK_HOME" "$GH_PR_ENRICH" install-skill >/dev/null
assert_true "$([ -L "$SYMLINK_HOME/real-codex-skills/gh-pr-enrich" ] && echo 0 || echo 1)" \
    "Codex installation supports a symlinked skills directory"
assert_true "$([ -L "$SYMLINK_HOME/real-claude-skills/gh-pr-enrich" ] && echo 0 || echo 1)" \
    "Claude installation supports a symlinked skills directory"
HOME="$SYMLINK_HOME" "$GH_PR_ENRICH" uninstall-skill >/dev/null
assert_true "$([ ! -L "$SYMLINK_HOME/real-codex-skills/gh-pr-enrich" ] && \
    [ ! -L "$SYMLINK_HOME/real-claude-skills/gh-pr-enrich" ] && echo 0 || echo 1)" \
    "symlinked skills directories uninstall both registrations"

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
# from its retained symlink inode. The rollback uses ln's no-overwrite behavior,
# so a concurrent replacement is never clobbered.
HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill >/dev/null
CODEX_PAYLOAD_BEFORE=$(readlink "$CODEX_SKILL")
CLAUDE_PAYLOAD_BEFORE=$(readlink "$CLAUDE_SKILL")
CODEX_IDENTITY_BEFORE=$(stat -c '%d:%i' "$CODEX_SKILL" 2>/dev/null || \
    stat -f '%d:%i' "$CODEX_SKILL")
FAIL_RM_STUBS="$TEST_OUTPUT_DIR/failing-uninstall-rm"
FAIL_RM_MARKER="$TEST_OUTPUT_DIR/failing-uninstall-rm.once"
mkdir -p "$FAIL_RM_STUBS"
cat > "$FAIL_RM_STUBS/rm" << 'STUB'
#!/bin/bash
case "$1" in
    "$FAIL_RM_PARENT"/.gh-pr-enrich-uninstall.*/gh-pr-enrich)
        if [ ! -e "$FAIL_RM_MARKER" ]; then
            : > "$FAIL_RM_MARKER"
            exit 73
        fi
        ;;
esac
exec /bin/rm "$@"
STUB
chmod +x "$FAIL_RM_STUBS/rm"
rc=0
env HOME="$TEST_HOME" FAIL_RM_PARENT="$(dirname "$CLAUDE_SKILL")" \
    FAIL_RM_MARKER="$FAIL_RM_MARKER" \
    PATH="$FAIL_RM_STUBS:$PATH" \
    "$GH_PR_ENRICH" uninstall-skill >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a second-runtime removal failure fails the transactional uninstall"
assert_eq "$CODEX_PAYLOAD_BEFORE" "$(readlink "$CODEX_SKILL")" \
    "a second-runtime removal failure restores the Codex symlink payload"
assert_eq "$CODEX_IDENTITY_BEFORE" \
    "$(stat -c '%d:%i' "$CODEX_SKILL" 2>/dev/null || stat -f '%d:%i' "$CODEX_SKILL")" \
    "a second-runtime removal failure restores the exact Codex symlink inode"
assert_eq "$CLAUDE_PAYLOAD_BEFORE" "$(readlink "$CLAUDE_SKILL")" \
    "a failed Claude removal preserves its captured symlink payload"
assert_no_skill_install_residue \
    "a failed two-runtime uninstall cleans its private claims"
HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill >/dev/null

# A rename wrapper can report failure after the exact registration has already
# moved into the private claim. Treat that response as ambiguous: restore the
# original inode and fail instead of committing an apparently successful move.
HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill --runtime codex >/dev/null
AMBIGUOUS_UNINSTALL_MV_STUBS="$TEST_OUTPUT_DIR/ambiguous-uninstall-mv"
AMBIGUOUS_UNINSTALL_IDENTITY=$(stat -c '%d:%i' "$CODEX_SKILL" 2>/dev/null || \
    stat -f '%d:%i' "$CODEX_SKILL")
mkdir -p "$AMBIGUOUS_UNINSTALL_MV_STUBS"
cat > "$AMBIGUOUS_UNINSTALL_MV_STUBS/mv" << 'STUB'
#!/bin/bash
if [ "$1" = "$AMBIGUOUS_UNINSTALL_TARGET" ]; then
    /bin/mv "$@" || exit $?
    exit 73
fi
exec /bin/mv "$@"
STUB
chmod +x "$AMBIGUOUS_UNINSTALL_MV_STUBS/mv"
rc=0
env HOME="$TEST_HOME" AMBIGUOUS_UNINSTALL_TARGET="$CODEX_SKILL" \
    PATH="$AMBIGUOUS_UNINSTALL_MV_STUBS:$PATH" \
    "$GH_PR_ENRICH" uninstall-skill --runtime codex >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "an ambiguous successful claim still fails uninstall"
assert_eq "$AMBIGUOUS_UNINSTALL_IDENTITY" \
    "$(stat -c '%d:%i' "$CODEX_SKILL" 2>/dev/null || stat -f '%d:%i' "$CODEX_SKILL")" \
    "an ambiguous successful claim restores the exact public registration"
assert_no_skill_install_residue \
    "an ambiguous successful claim cleans every private reference"
HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill --runtime codex >/dev/null

# Cancellation can arrive while the first runtime's preflight hard link is
# being created. No public claim has started, so cleanup removes only private
# references and preserves both exact public registrations.
HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill >/dev/null
PREFLIGHT_SIGNAL_STUBS="$TEST_OUTPUT_DIR/uninstall-preflight-signal"
PREFLIGHT_SIGNAL_MARKER="$TEST_OUTPUT_DIR/uninstall-preflight-signal.once"
CODEX_IDENTITY_BEFORE=$(stat -c '%d:%i' "$CODEX_SKILL" 2>/dev/null || \
    stat -f '%d:%i' "$CODEX_SKILL")
CLAUDE_IDENTITY_BEFORE=$(stat -c '%d:%i' "$CLAUDE_SKILL" 2>/dev/null || \
    stat -f '%d:%i' "$CLAUDE_SKILL")
mkdir -p "$PREFLIGHT_SIGNAL_STUBS"
cat > "$PREFLIGHT_SIGNAL_STUBS/ln" << 'STUB'
#!/bin/bash
if [ "$1" = -P ] && [ "$2" = "$PREFLIGHT_SIGNAL_TARGET" ] && \
   [ ! -e "$PREFLIGHT_SIGNAL_MARKER" ]; then
    /bin/ln "$@" || exit $?
    : > "$PREFLIGHT_SIGNAL_MARKER"
    kill -TERM "$PPID"
    exit 0
fi
exec /bin/ln "$@"
STUB
chmod +x "$PREFLIGHT_SIGNAL_STUBS/ln"
rc=0
env HOME="$TEST_HOME" PREFLIGHT_SIGNAL_TARGET="$CODEX_SKILL" \
    PREFLIGHT_SIGNAL_MARKER="$PREFLIGHT_SIGNAL_MARKER" \
    PATH="$PREFLIGHT_SIGNAL_STUBS:$PATH" \
    "$GH_PR_ENRICH" uninstall-skill >/dev/null 2>&1 || rc=$?
assert_eq "143" "$rc" \
    "TERM during uninstall preflight reference creation preserves its status"
assert_eq "$CODEX_IDENTITY_BEFORE" \
    "$(stat -c '%d:%i' "$CODEX_SKILL" 2>/dev/null || stat -f '%d:%i' "$CODEX_SKILL")" \
    "preflight cancellation preserves the exact Codex registration"
assert_eq "$CLAUDE_IDENTITY_BEFORE" \
    "$(stat -c '%d:%i' "$CLAUDE_SKILL" 2>/dev/null || stat -f '%d:%i' "$CLAUDE_SKILL")" \
    "preflight cancellation preserves the exact Claude registration"
assert_no_skill_install_residue \
    "preflight cancellation cleans every private reference"
HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill >/dev/null

# Replacement at the public-to-private claim boundary must never be deleted,
# even when it has the same payload as the captured registration. The claimed
# replacement is restored with its exact symlink inode and uninstall fails.
UNINSTALL_RACE_STUBS="$TEST_OUTPUT_DIR/uninstall-race-stubs"
UNINSTALL_RACE_IDENTITY="$TEST_OUTPUT_DIR/uninstall-race-identity"
mkdir -p "$UNINSTALL_RACE_STUBS" "$TEST_OUTPUT_DIR/concurrent-skill-source"
cat > "$UNINSTALL_RACE_STUBS/mv" << 'STUB'
#!/bin/bash
if [ "$1" = "$UNINSTALL_RACE_TARGET" ]; then
    /bin/rm "$UNINSTALL_RACE_TARGET" || exit 74
    /bin/ln -s "$UNINSTALL_RACE_PAYLOAD" "$UNINSTALL_RACE_TARGET" || exit 75
    stat -c '%d:%i' "$UNINSTALL_RACE_TARGET" 2>/dev/null > "$UNINSTALL_RACE_IDENTITY" || \
        stat -f '%d:%i' "$UNINSTALL_RACE_TARGET" > "$UNINSTALL_RACE_IDENTITY" || exit 76
fi
exec /bin/mv "$@"
STUB
chmod +x "$UNINSTALL_RACE_STUBS/mv"

for UNINSTALL_RACE_KIND in different_payload same_payload; do
    HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill --runtime codex >/dev/null
    if [ "$UNINSTALL_RACE_KIND" = different_payload ]; then
        UNINSTALL_RACE_PAYLOAD="$TEST_OUTPUT_DIR/concurrent-skill-source"
    else
        UNINSTALL_RACE_PAYLOAD="$(readlink "$CODEX_SKILL")"
    fi
    rm -f "$UNINSTALL_RACE_IDENTITY"
    rc=0
    env HOME="$TEST_HOME" UNINSTALL_RACE_TARGET="$CODEX_SKILL" \
        UNINSTALL_RACE_PAYLOAD="$UNINSTALL_RACE_PAYLOAD" \
        UNINSTALL_RACE_IDENTITY="$UNINSTALL_RACE_IDENTITY" \
        PATH="$UNINSTALL_RACE_STUBS:$PATH" \
        "$GH_PR_ENRICH" uninstall-skill --runtime codex \
        >/dev/null 2>&1 || rc=$?
    assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
        "$UNINSTALL_RACE_KIND claim-boundary replacement fails uninstall"
    assert_eq "$UNINSTALL_RACE_PAYLOAD" "$(readlink "$CODEX_SKILL")" \
        "$UNINSTALL_RACE_KIND claim-boundary replacement keeps its payload"
    assert_eq "$(cat "$UNINSTALL_RACE_IDENTITY")" \
        "$(stat -c '%d:%i' "$CODEX_SKILL" 2>/dev/null || stat -f '%d:%i' "$CODEX_SKILL")" \
        "$UNINSTALL_RACE_KIND claim-boundary replacement keeps its exact inode"
    assert_no_skill_install_residue \
        "$UNINSTALL_RACE_KIND claim-boundary replacement cleans its private claim"
    HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill --runtime codex >/dev/null
done

# A new public registration can appear after the captured symlink is correctly
# claimed but before its private name is removed. Claim removal must touch only
# the private inode and leave the concurrent public registration exact.
UNINSTALL_REMOVE_RACE_STUBS="$TEST_OUTPUT_DIR/uninstall-remove-race-stubs"
UNINSTALL_REMOVE_RACE_MARKER="$TEST_OUTPUT_DIR/uninstall-remove-race.once"
UNINSTALL_REMOVE_RACE_IDENTITY="$TEST_OUTPUT_DIR/uninstall-remove-race-identity"
UNINSTALL_REMOVE_RACE_PAYLOAD="$TEST_OUTPUT_DIR/concurrent-skill-source"
mkdir -p "$UNINSTALL_REMOVE_RACE_STUBS"
cat > "$UNINSTALL_REMOVE_RACE_STUBS/rm" << 'STUB'
#!/bin/bash
case "$1" in
    "$UNINSTALL_REMOVE_RACE_PARENT"/.gh-pr-enrich-uninstall.*/gh-pr-enrich)
        if [ ! -e "$UNINSTALL_REMOVE_RACE_MARKER" ]; then
            : > "$UNINSTALL_REMOVE_RACE_MARKER"
            /bin/ln -s "$UNINSTALL_REMOVE_RACE_PAYLOAD" \
                "$UNINSTALL_REMOVE_RACE_TARGET" || exit 74
            stat -c '%d:%i' "$UNINSTALL_REMOVE_RACE_TARGET" 2>/dev/null \
                > "$UNINSTALL_REMOVE_RACE_IDENTITY" || \
                stat -f '%d:%i' "$UNINSTALL_REMOVE_RACE_TARGET" \
                    > "$UNINSTALL_REMOVE_RACE_IDENTITY" || exit 75
        fi
        ;;
esac
exec /bin/rm "$@"
STUB
chmod +x "$UNINSTALL_REMOVE_RACE_STUBS/rm"
HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill --runtime codex >/dev/null
rm -f "$UNINSTALL_REMOVE_RACE_MARKER" "$UNINSTALL_REMOVE_RACE_IDENTITY"
env HOME="$TEST_HOME" \
    UNINSTALL_REMOVE_RACE_PARENT="$(dirname "$CODEX_SKILL")" \
    UNINSTALL_REMOVE_RACE_TARGET="$CODEX_SKILL" \
    UNINSTALL_REMOVE_RACE_PAYLOAD="$UNINSTALL_REMOVE_RACE_PAYLOAD" \
    UNINSTALL_REMOVE_RACE_MARKER="$UNINSTALL_REMOVE_RACE_MARKER" \
    UNINSTALL_REMOVE_RACE_IDENTITY="$UNINSTALL_REMOVE_RACE_IDENTITY" \
    PATH="$UNINSTALL_REMOVE_RACE_STUBS:$PATH" \
    "$GH_PR_ENRICH" uninstall-skill --runtime codex >/dev/null
assert_eq "$UNINSTALL_REMOVE_RACE_PAYLOAD" "$(readlink "$CODEX_SKILL")" \
    "claim removal preserves a concurrent public registration payload"
assert_eq "$(cat "$UNINSTALL_REMOVE_RACE_IDENTITY")" \
    "$(stat -c '%d:%i' "$CODEX_SKILL" 2>/dev/null || stat -f '%d:%i' "$CODEX_SKILL")" \
    "claim removal preserves the exact concurrent public registration inode"
assert_no_skill_install_residue \
    "claim removal with a concurrent public registration cleans private residue"
/bin/rm "$CODEX_SKILL"

# A directory has no portable atomic create-if-absent restore primitive. If one
# wins the public path at the claim boundary, preserve it privately and report
# the exact recovery path instead of nesting it or deleting it.
UNINSTALL_DIRECTORY_STUBS="$TEST_OUTPUT_DIR/uninstall-directory-stubs"
mkdir -p "$UNINSTALL_DIRECTORY_STUBS"
cat > "$UNINSTALL_DIRECTORY_STUBS/mv" << 'STUB'
#!/bin/bash
if [ "$1" = "$UNINSTALL_DIRECTORY_TARGET" ]; then
    /bin/rm "$UNINSTALL_DIRECTORY_TARGET" || exit 74
    /bin/mkdir "$UNINSTALL_DIRECTORY_TARGET" || exit 75
    printf 'concurrent directory\n' > "$UNINSTALL_DIRECTORY_TARGET/marker"
fi
exec /bin/mv "$@"
STUB
chmod +x "$UNINSTALL_DIRECTORY_STUBS/mv"
HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill --runtime codex >/dev/null
rc=0
UNINSTALL_DIRECTORY_OUT=$(env HOME="$TEST_HOME" \
    UNINSTALL_DIRECTORY_TARGET="$CODEX_SKILL" \
    PATH="$UNINSTALL_DIRECTORY_STUBS:$PATH" \
    "$GH_PR_ENRICH" uninstall-skill --runtime codex 2>&1) || rc=$?
UNINSTALL_DIRECTORY_CLAIM=$(find "$(dirname "$CODEX_SKILL")" -maxdepth 1 \
    -type d -name '.gh-pr-enrich-uninstall.*' -print -quit)
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a claim-boundary directory replacement fails uninstall"
assert_true "$([ -n "$UNINSTALL_DIRECTORY_CLAIM" ] && \
    [ -f "$UNINSTALL_DIRECTORY_CLAIM/gh-pr-enrich/marker" ] && echo 0 || echo 1)" \
    "the concurrently claimed directory remains privately recoverable"
assert_contains "$UNINSTALL_DIRECTORY_OUT" \
    "$UNINSTALL_DIRECTORY_CLAIM/gh-pr-enrich" \
    "directory claim failure reports the exact recovery path"
assert_true "$([ ! -e "$CODEX_SKILL" ] && [ ! -L "$CODEX_SKILL" ] && echo 0 || echo 1)" \
    "directory claim recovery never creates a nested public registration"
/bin/rm -rf "$UNINSTALL_DIRECTORY_CLAIM"

# A newer public directory can appear after a mismatched symlink is claimed but
# before restoration. Exact-basename linking into the parent must fail without
# nesting into or replacing that directory; the displaced symlink stays private.
UNINSTALL_RESTORE_COLLISION_STUBS="$TEST_OUTPUT_DIR/uninstall-restore-collision-stubs"
UNINSTALL_RESTORE_PAYLOAD="$TEST_OUTPUT_DIR/uninstall-restore-payload"
mkdir -p "$UNINSTALL_RESTORE_COLLISION_STUBS" "$UNINSTALL_RESTORE_PAYLOAD"
cat > "$UNINSTALL_RESTORE_COLLISION_STUBS/mv" << 'STUB'
#!/bin/bash
if [ "$1" = "$UNINSTALL_RESTORE_TARGET" ]; then
    /bin/rm "$UNINSTALL_RESTORE_TARGET" || exit 74
    /bin/ln -s "$UNINSTALL_RESTORE_PAYLOAD" "$UNINSTALL_RESTORE_TARGET" || exit 75
fi
exec /bin/mv "$@"
STUB
cat > "$UNINSTALL_RESTORE_COLLISION_STUBS/ln" << 'STUB'
#!/bin/bash
target="${!#}"
source_index=$(( $# - 1 ))
source_path="${!source_index}"
case "$source_path" in
    "$UNINSTALL_RESTORE_PARENT"/.gh-pr-enrich-uninstall.*/gh-pr-enrich)
        if [ "$target" = "$UNINSTALL_RESTORE_PARENT" ]; then
            /bin/mkdir "$UNINSTALL_RESTORE_TARGET" || exit 76
            printf 'newer directory\n' > "$UNINSTALL_RESTORE_TARGET/marker"
        fi
        ;;
esac
exec /bin/ln "$@"
STUB
chmod +x "$UNINSTALL_RESTORE_COLLISION_STUBS/mv" \
    "$UNINSTALL_RESTORE_COLLISION_STUBS/ln"
HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill --runtime codex >/dev/null
rc=0
UNINSTALL_RESTORE_OUT=$(env HOME="$TEST_HOME" \
    UNINSTALL_RESTORE_TARGET="$CODEX_SKILL" \
    UNINSTALL_RESTORE_PARENT="$(dirname "$CODEX_SKILL")" \
    UNINSTALL_RESTORE_PAYLOAD="$UNINSTALL_RESTORE_PAYLOAD" \
    PATH="$UNINSTALL_RESTORE_COLLISION_STUBS:$PATH" \
    "$GH_PR_ENRICH" uninstall-skill --runtime codex 2>&1) || rc=$?
UNINSTALL_RESTORE_CLAIM=$(find "$(dirname "$CODEX_SKILL")" -maxdepth 1 \
    -type d -name '.gh-pr-enrich-uninstall.*' -print -quit)
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a restore-boundary directory collision fails uninstall"
assert_eq "newer directory" "$(cat "$CODEX_SKILL/marker")" \
    "restore rollback preserves the newer public directory"
assert_true "$([ ! -e "$CODEX_SKILL/gh-pr-enrich" ] && echo 0 || echo 1)" \
    "restore rollback never nests a registration in the newer directory"
assert_eq "$UNINSTALL_RESTORE_PAYLOAD" \
    "$(readlink "$UNINSTALL_RESTORE_CLAIM/gh-pr-enrich")" \
    "restore rollback preserves the displaced symlink in its private claim"
assert_contains "$UNINSTALL_RESTORE_OUT" \
    "$UNINSTALL_RESTORE_CLAIM/gh-pr-enrich" \
    "restore collision reports the displaced symlink recovery path"
/bin/rm -rf "$CODEX_SKILL" "$UNINSTALL_RESTORE_CLAIM"

# Signals delivered by a removal child are observed after that child returns.
# The transaction must recheck the pending signal before committing and restore
# both exact registrations with the conventional status.
UNINSTALL_SIGNAL_STUBS="$TEST_OUTPUT_DIR/uninstall-signal-stubs"
mkdir -p "$UNINSTALL_SIGNAL_STUBS"
cat > "$UNINSTALL_SIGNAL_STUBS/rm" << 'STUB'
#!/bin/bash
case "$1" in
    "$UNINSTALL_SIGNAL_PARENT"/.gh-pr-enrich-uninstall.*/gh-pr-enrich)
        if [ ! -e "$UNINSTALL_SIGNAL_MARKER" ]; then
            /bin/rm "$@" || exit $?
            : > "$UNINSTALL_SIGNAL_MARKER"
            kill -"$UNINSTALL_SIGNAL_NAME" "$PPID"
            exit 0
        fi
        ;;
esac
exec /bin/rm "$@"
STUB
chmod +x "$UNINSTALL_SIGNAL_STUBS/rm"

for UNINSTALL_SIGNAL_CASE in TERM:codex:143 INT:claude:130; do
    IFS=: read -r UNINSTALL_SIGNAL_NAME UNINSTALL_SIGNAL_RUNTIME \
        UNINSTALL_SIGNAL_STATUS <<< "$UNINSTALL_SIGNAL_CASE"
    HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill >/dev/null
    CODEX_IDENTITY_BEFORE=$(stat -c '%d:%i' "$CODEX_SKILL" 2>/dev/null || \
        stat -f '%d:%i' "$CODEX_SKILL")
    CLAUDE_IDENTITY_BEFORE=$(stat -c '%d:%i' "$CLAUDE_SKILL" 2>/dev/null || \
        stat -f '%d:%i' "$CLAUDE_SKILL")
    if [ "$UNINSTALL_SIGNAL_RUNTIME" = codex ]; then
        UNINSTALL_SIGNAL_PARENT="$(dirname "$CODEX_SKILL")"
    else
        UNINSTALL_SIGNAL_PARENT="$(dirname "$CLAUDE_SKILL")"
    fi
    UNINSTALL_SIGNAL_MARKER="$TEST_OUTPUT_DIR/uninstall-signal-$UNINSTALL_SIGNAL_RUNTIME"
    rm -f "$UNINSTALL_SIGNAL_MARKER"
    rc=0
    env HOME="$TEST_HOME" UNINSTALL_SIGNAL_NAME="$UNINSTALL_SIGNAL_NAME" \
        UNINSTALL_SIGNAL_PARENT="$UNINSTALL_SIGNAL_PARENT" \
        UNINSTALL_SIGNAL_MARKER="$UNINSTALL_SIGNAL_MARKER" \
        PATH="$UNINSTALL_SIGNAL_STUBS:$PATH" \
        "$GH_PR_ENRICH" uninstall-skill >/dev/null 2>&1 || rc=$?
    assert_eq "$UNINSTALL_SIGNAL_STATUS" "$rc" \
        "$UNINSTALL_SIGNAL_NAME during $UNINSTALL_SIGNAL_RUNTIME claim removal preserves its status"
    assert_eq "$CODEX_IDENTITY_BEFORE" \
        "$(stat -c '%d:%i' "$CODEX_SKILL" 2>/dev/null || stat -f '%d:%i' "$CODEX_SKILL")" \
        "$UNINSTALL_SIGNAL_NAME during claim removal restores the exact Codex registration"
    assert_eq "$CLAUDE_IDENTITY_BEFORE" \
        "$(stat -c '%d:%i' "$CLAUDE_SKILL" 2>/dev/null || stat -f '%d:%i' "$CLAUDE_SKILL")" \
        "$UNINSTALL_SIGNAL_NAME during claim removal restores the exact Claude registration"
    assert_no_skill_install_residue \
        "$UNINSTALL_SIGNAL_NAME during claim removal cleans private claims"
    HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill >/dev/null
done

# A DEBUG hook makes the last pre-commit boundary deterministic by signaling
# immediately before the committed flag is assigned. The post-assignment guard
# must turn the transaction back into rollback mode, restore both exact public
# registrations, and preserve the conventional signal status.
UNINSTALL_COMMIT_SIGNAL_BASH_ENV="$TEST_OUTPUT_DIR/uninstall-commit-signal-bash-env"
UNINSTALL_COMMIT_SIGNAL_MARKER="$TEST_OUTPUT_DIR/uninstall-commit-signal-fired"
cat > "$UNINSTALL_COMMIT_SIGNAL_BASH_ENV" << 'STUB'
__gh_pr_enrich_uninstall_commit_debug() {
    if [ "$BASH_COMMAND" = 'UNINSTALL_TRANSACTION_COMMITTED=true' ] && \
       [ ! -e "$UNINSTALL_COMMIT_SIGNAL_MARKER" ]; then
        : > "$UNINSTALL_COMMIT_SIGNAL_MARKER"
        kill -TERM "$$"
    fi
}
set -T
trap '__gh_pr_enrich_uninstall_commit_debug' DEBUG
STUB
HOME="$TEST_HOME" "$GH_PR_ENRICH" install-skill >/dev/null
CODEX_IDENTITY_BEFORE=$(stat -c '%d:%i' "$CODEX_SKILL" 2>/dev/null || \
    stat -f '%d:%i' "$CODEX_SKILL")
CLAUDE_IDENTITY_BEFORE=$(stat -c '%d:%i' "$CLAUDE_SKILL" 2>/dev/null || \
    stat -f '%d:%i' "$CLAUDE_SKILL")
rc=0
env HOME="$TEST_HOME" BASH_ENV="$UNINSTALL_COMMIT_SIGNAL_BASH_ENV" \
    UNINSTALL_COMMIT_SIGNAL_MARKER="$UNINSTALL_COMMIT_SIGNAL_MARKER" \
    "$GH_PR_ENRICH" uninstall-skill >/dev/null 2>&1 || rc=$?
assert_true "$([ -e "$UNINSTALL_COMMIT_SIGNAL_MARKER" ] && echo 0 || echo 1)" \
    "the uninstall commit-boundary regression reaches the final assignment"
assert_eq "143" "$rc" \
    "TERM at the final uninstall commit boundary preserves its status"
assert_eq "$CODEX_IDENTITY_BEFORE" \
    "$(stat -c '%d:%i' "$CODEX_SKILL" 2>/dev/null || stat -f '%d:%i' "$CODEX_SKILL")" \
    "commit-boundary cancellation restores the exact Codex registration"
assert_eq "$CLAUDE_IDENTITY_BEFORE" \
    "$(stat -c '%d:%i' "$CLAUDE_SKILL" 2>/dev/null || stat -f '%d:%i' "$CLAUDE_SKILL")" \
    "commit-boundary cancellation restores the exact Claude registration"
assert_no_skill_install_residue \
    "commit-boundary cancellation cleans every private reference"
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

# A non-symlink target created after preflight must make publication fail
# without being nested into or displaced from the public registration path.
INSTALL_COLLISION_STUBS="$TEST_OUTPUT_DIR/install-collision-stubs"
mkdir -p "$INSTALL_COLLISION_STUBS"
cat > "$INSTALL_COLLISION_STUBS/ln" << 'STUB'
#!/bin/bash
target="${!#}"
source_index=$(( $# - 1 ))
source_path="${!source_index}"
published_path="$target/$(basename "$source_path")"
if [ "$published_path" = "$COLLISION_CODEX_TARGET" ]; then
    case "$source_path" in
        */.gh-pr-enrich-install.*/claim/gh-pr-enrich)
            exec /bin/ln "$@"
            ;;
    esac
    case "$COLLISION_KIND" in
        file) printf '%s\n' 'operator-owned-file' > "$published_path" ;;
        directory)
            /bin/mkdir "$published_path" || exit 74
            printf '%s\n' 'operator-owned-directory' > "$published_path/owner"
            ;;
    esac
fi
exec /bin/ln "$@"
STUB
chmod +x "$INSTALL_COLLISION_STUBS/ln"

rc=0
env HOME="$TEST_HOME" COLLISION_CODEX_TARGET="$CODEX_SKILL" \
    COLLISION_KIND=file PATH="$INSTALL_COLLISION_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a concurrent regular-file registration fails installation"
assert_eq "operator-owned-file" "$(cat "$CODEX_SKILL")" \
    "regular-file collision remains unchanged at the public path"
assert_no_skill_install_residue \
    "regular-file collision leaves no private transaction residue"
rm "$CODEX_SKILL"

rc=0
env HOME="$TEST_HOME" COLLISION_CODEX_TARGET="$CODEX_SKILL" \
    COLLISION_KIND=directory PATH="$INSTALL_COLLISION_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a concurrent directory registration fails installation"
assert_eq "operator-owned-directory" "$(cat "$CODEX_SKILL/owner")" \
    "directory collision remains unchanged at the public path"
assert_true "$([ ! -e "$CODEX_SKILL/gh-pr-enrich" ] && \
    [ ! -L "$CODEX_SKILL/gh-pr-enrich" ] && echo 0 || echo 1)" \
    "directory collision never receives a nested registration"
assert_no_skill_install_residue \
    "directory collision leaves no private transaction residue"
rm "$CODEX_SKILL/owner"
rmdir "$CODEX_SKILL"

# A successful second-runtime publication is not the transaction commit. Both
# public registrations must still match the sources validated by the installer.
COMMIT_REVALIDATION_STUBS="$TEST_OUTPUT_DIR/commit-revalidation-stubs"
CONCURRENT_COMMIT_SOURCE="$TEST_OUTPUT_DIR/concurrent-commit-source"
mkdir -p "$COMMIT_REVALIDATION_STUBS" "$CONCURRENT_COMMIT_SOURCE"
cat > "$COMMIT_REVALIDATION_STUBS/ln" << 'STUB'
#!/bin/bash
target="${!#}"
source_index=$(( $# - 1 ))
source_path="${!source_index}"
published_path="$target/$(basename "$source_path")"
if [ "$published_path" = "$COMMIT_REVALIDATION_CLAUDE_TARGET" ]; then
    /bin/ln "$@" || exit $?
    /bin/rm "$COMMIT_REVALIDATION_CODEX_TARGET" || exit 74
    /bin/ln -s "$CONCURRENT_COMMIT_SOURCE" \
        "$COMMIT_REVALIDATION_CODEX_TARGET" || exit 75
    exit 0
fi
exec /bin/ln "$@"
STUB
chmod +x "$COMMIT_REVALIDATION_STUBS/ln"
rc=0
COMMIT_REVALIDATION_OUTPUT=$(env HOME="$TEST_HOME" \
    COMMIT_REVALIDATION_CODEX_TARGET="$CODEX_SKILL" \
    COMMIT_REVALIDATION_CLAUDE_TARGET="$CLAUDE_SKILL" \
    CONCURRENT_COMMIT_SOURCE="$CONCURRENT_COMMIT_SOURCE" \
    PATH="$COMMIT_REVALIDATION_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "commit revalidation rejects a concurrently replaced Codex registration"
assert_eq "$CONCURRENT_COMMIT_SOURCE" "$(readlink "$CODEX_SKILL")" \
    "failed commit revalidation preserves the concurrent Codex registration"
assert_true "$([ ! -L "$CLAUDE_SKILL" ] && echo 0 || echo 1)" \
    "failed commit revalidation rolls back the owned Claude registration"
assert_contains "$COMMIT_REVALIDATION_OUTPUT" \
    "Codex registration changed before install commit" \
    "commit revalidation reports the inconsistent runtime"
assert_no_skill_install_residue \
    "commit revalidation leaves no private transaction residue"
rm "$CODEX_SKILL"

# If the second runtime fails after another installer replaces the Codex
# registration, rollback must not remove the concurrent installer's symlink.
CONCURRENT_INSTALL_STUBS="$TEST_OUTPUT_DIR/concurrent-install-stubs"
mkdir -p "$CONCURRENT_INSTALL_STUBS"
cat > "$CONCURRENT_INSTALL_STUBS/ln" << 'STUB'
#!/bin/bash
target="${!#}"
source_index=$(( $# - 1 ))
source_path="${!source_index}"
published_path="$target/$(basename "$source_path")"
if [ "$published_path" = "$CONCURRENT_CODEX_TARGET" ]; then
    /bin/ln "$@" || exit $?
    payload=$(/usr/bin/readlink "$CONCURRENT_CODEX_TARGET") || exit 74
    replacement="$CONCURRENT_CODEX_TARGET.concurrent"
    /bin/ln -s "$payload" "$replacement" || exit 75
    /bin/rm "$CONCURRENT_CODEX_TARGET" || exit 76
    /bin/mv "$replacement" "$CONCURRENT_CODEX_TARGET" || exit 77
    exit 0
fi
if [ "$published_path" = "$FAIL_CLAUDE_INSTALL_TARGET" ]; then
    exit 73
fi
exec /bin/ln "$@"
STUB
chmod +x "$CONCURRENT_INSTALL_STUBS/ln"
rc=0
env HOME="$TEST_HOME" FAIL_CLAUDE_INSTALL_TARGET="$CLAUDE_SKILL" \
    CONCURRENT_CODEX_TARGET="$CODEX_SKILL" \
    PATH="$CONCURRENT_INSTALL_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a second-runtime install failure fails the transactional install"
assert_true "$([ -L "$CODEX_SKILL" ] && echo 0 || echo 1)" \
    "install rollback preserves a concurrently replaced Codex registration"
assert_eq "$(dirname "$CANONICAL_SKILL")" "$(readlink "$CODEX_SKILL")" \
    "the preserved concurrent registration retains its symlink payload"
HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill --runtime codex >/dev/null

# Replacement immediately before rollback's atomic claim is also preserved.
ROLLBACK_CLAIM_STUBS="$TEST_OUTPUT_DIR/rollback-claim-stubs"
mkdir -p "$ROLLBACK_CLAIM_STUBS"
cat > "$ROLLBACK_CLAIM_STUBS/ln" << 'STUB'
#!/bin/bash
target="${!#}"
source_index=$(( $# - 1 ))
source_path="${!source_index}"
published_path="$target/$(basename "$source_path")"
if [ "$published_path" = "$FAIL_CLAUDE_INSTALL_TARGET" ]; then
    exit 73
fi
exec /bin/ln "$@"
STUB
cat > "$ROLLBACK_CLAIM_STUBS/mv" << 'STUB'
#!/bin/bash
if [ "$1" = "$CONCURRENT_CODEX_TARGET" ]; then
    payload=$(/usr/bin/readlink "$CONCURRENT_CODEX_TARGET") || exit 74
    replacement="$CONCURRENT_CODEX_TARGET.concurrent"
    /bin/ln -s "$payload" "$replacement" || exit 75
    /bin/rm "$CONCURRENT_CODEX_TARGET" || exit 76
    /bin/mv "$replacement" "$CONCURRENT_CODEX_TARGET" || exit 77
fi
exec /bin/mv "$@"
STUB
chmod +x "$ROLLBACK_CLAIM_STUBS/ln" "$ROLLBACK_CLAIM_STUBS/mv"
rc=0
env HOME="$TEST_HOME" FAIL_CLAUDE_INSTALL_TARGET="$CLAUDE_SKILL" \
    CONCURRENT_CODEX_TARGET="$CODEX_SKILL" \
    PATH="$ROLLBACK_CLAIM_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a rollback-boundary replacement still fails the two-runtime install"
assert_true "$([ -L "$CODEX_SKILL" ] && echo 0 || echo 1)" \
    "atomic rollback claim restores a concurrently replaced Codex registration"
assert_eq "$(dirname "$CANONICAL_SKILL")" "$(readlink "$CODEX_SKILL")" \
    "rollback-boundary restoration preserves the concurrent symlink payload"
HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill --runtime codex >/dev/null

# A move wrapper can report failure after the atomic rename already completed.
# Rollback must detect and finish processing that detached claim.
POST_CLAIM_FAILURE_STUBS="$TEST_OUTPUT_DIR/post-claim-failure-stubs"
mkdir -p "$POST_CLAIM_FAILURE_STUBS"
cat > "$POST_CLAIM_FAILURE_STUBS/ln" << 'STUB'
#!/bin/bash
target="${!#}"
source_index=$(( $# - 1 ))
source_path="${!source_index}"
published_path="$target/$(basename "$source_path")"
if [ "$published_path" = "$FAIL_CLAUDE_INSTALL_TARGET" ]; then
    exit 73
fi
exec /bin/ln "$@"
STUB
cat > "$POST_CLAIM_FAILURE_STUBS/mv" << 'STUB'
#!/bin/bash
if [ "$1" = "$POST_CLAIM_CODEX_TARGET" ]; then
    /bin/mv "$@" || exit $?
    kill -TERM "$PPID"
    exit 73
fi
exec /bin/mv "$@"
STUB
chmod +x "$POST_CLAIM_FAILURE_STUBS/ln" "$POST_CLAIM_FAILURE_STUBS/mv"
rc=0
POST_CLAIM_FAILURE_OUTPUT=$(env HOME="$TEST_HOME" \
    FAIL_CLAUDE_INSTALL_TARGET="$CLAUDE_SKILL" \
    POST_CLAIM_CODEX_TARGET="$CODEX_SKILL" \
    PATH="$POST_CLAIM_FAILURE_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill 2>&1) || rc=$?
assert_eq "1" "$rc" \
    "repeated cleanup TERM preserves the original install failure status"
assert_true "$([ ! -L "$CODEX_SKILL" ] && [ ! -L "$CLAUDE_SKILL" ] && echo 0 || echo 1)" \
    "post-rename claim failure completes the owned rollback"
assert_contains "$POST_CLAIM_FAILURE_OUTPUT" \
    "reported failure after detaching" \
    "post-rename claim failure is distinguished from an untouched target"
assert_no_skill_install_residue \
    "a repeated cleanup signal cannot strand private claim residue"

# If rollback cannot identify a detached symlink, it must not republish an
# indeterminate object as if it were a concurrent registration.
CLAIM_METADATA_STUBS="$TEST_OUTPUT_DIR/claim-metadata-stubs"
mkdir -p "$CLAIM_METADATA_STUBS"
cat > "$CLAIM_METADATA_STUBS/ln" << 'STUB'
#!/bin/bash
target="${!#}"
source_index=$(( $# - 1 ))
source_path="${!source_index}"
published_path="$target/$(basename "$source_path")"
if [ "$published_path" = "$FAIL_CLAUDE_INSTALL_TARGET" ]; then
    exit 73
fi
exec /bin/ln "$@"
STUB
cat > "$CLAIM_METADATA_STUBS/stat" << 'STUB'
#!/bin/bash
target="${!#}"
case "$target" in
    */.gh-pr-enrich-install.*/claim/gh-pr-enrich) exit 73 ;;
esac
exec /usr/bin/stat "$@"
STUB
chmod +x "$CLAIM_METADATA_STUBS/ln" "$CLAIM_METADATA_STUBS/stat"
rc=0
CLAIM_METADATA_OUTPUT=$(env HOME="$TEST_HOME" \
    FAIL_CLAUDE_INSTALL_TARGET="$CLAUDE_SKILL" \
    PATH="$CLAIM_METADATA_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill 2>&1) || rc=$?
CLAIM_METADATA_PATH=$(find "$TEST_HOME/.codex/skills" \
    -path '*/.gh-pr-enrich-install.*/claim/gh-pr-enrich' \
    -type l -print -quit)
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "rollback metadata failure fails the two-runtime install"
assert_true "$([ ! -L "$CODEX_SKILL" ] && [ -L "$CLAIM_METADATA_PATH" ] && echo 0 || echo 1)" \
    "indeterminate claimed registration stays private and recoverable"
assert_contains "$CLAIM_METADATA_OUTPUT" "preserved at" \
    "rollback metadata failure reports the recovery path"
rm "$CLAIM_METADATA_PATH"
rmdir "$(dirname "$CLAIM_METADATA_PATH")"
rmdir "$(dirname "$(dirname "$CLAIM_METADATA_PATH")")"

# A directory replacement in the narrow window after the directory pre-check
# cannot be atomically restored. It must remain recoverable and be reported.
DIRECTORY_CLAIM_STUBS="$TEST_OUTPUT_DIR/directory-claim-stubs"
mkdir -p "$DIRECTORY_CLAIM_STUBS"
cat > "$DIRECTORY_CLAIM_STUBS/ln" << 'STUB'
#!/bin/bash
target="${!#}"
source_index=$(( $# - 1 ))
source_path="${!source_index}"
published_path="$target/$(basename "$source_path")"
if [ "$published_path" = "$FAIL_CLAUDE_INSTALL_TARGET" ]; then
    exit 73
fi
exec /bin/ln "$@"
STUB
cat > "$DIRECTORY_CLAIM_STUBS/mv" << 'STUB'
#!/bin/bash
if [ "$1" = "$CONCURRENT_CODEX_TARGET" ]; then
    /bin/rm "$CONCURRENT_CODEX_TARGET" || exit 74
    /bin/mkdir "$CONCURRENT_CODEX_TARGET" || exit 75
    printf '%s\n' 'concurrent-directory' > "$CONCURRENT_CODEX_TARGET/owner"
fi
exec /bin/mv "$@"
STUB
chmod +x "$DIRECTORY_CLAIM_STUBS/ln" "$DIRECTORY_CLAIM_STUBS/mv"
rc=0
DIRECTORY_CLAIM_OUTPUT=$(env HOME="$TEST_HOME" \
    FAIL_CLAUDE_INSTALL_TARGET="$CLAUDE_SKILL" \
    CONCURRENT_CODEX_TARGET="$CODEX_SKILL" \
    PATH="$DIRECTORY_CLAIM_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill 2>&1) || rc=$?
DIRECTORY_CLAIMED=$(find "$TEST_HOME/.codex/skills" \
    -path '*/.gh-pr-enrich-install.*/claim/gh-pr-enrich' \
    -type d -print -quit)
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a claim-boundary directory replacement fails the install"
assert_eq "concurrent-directory" "$(cat "$DIRECTORY_CLAIMED/owner")" \
    "a claimed concurrent directory remains recoverable with its contents"
assert_contains "$DIRECTORY_CLAIM_OUTPUT" "preserved at" \
    "directory claim collision reports the recovery path"
rm "$DIRECTORY_CLAIMED/owner"
rmdir "$DIRECTORY_CLAIMED"
rmdir "$(dirname "$DIRECTORY_CLAIMED")"
rmdir "$(dirname "$(dirname "$DIRECTORY_CLAIMED")")"

# If a newer registration appears after rollback claims a concurrent one,
# restoration must not overwrite it and the claimed link must stay recoverable.
RESTORE_RACE_STUBS="$TEST_OUTPUT_DIR/restore-race-stubs"
NEWER_REGISTRATION_SOURCE="$TEST_OUTPUT_DIR/newer-registration-source"
mkdir -p "$RESTORE_RACE_STUBS" "$NEWER_REGISTRATION_SOURCE"
cat > "$RESTORE_RACE_STUBS/ln" << 'STUB'
#!/bin/bash
target="${!#}"
source_index=$(( $# - 1 ))
source_path="${!source_index}"
published_path="$target/$(basename "$source_path")"
if [ "$published_path" = "$CONCURRENT_CODEX_TARGET" ]; then
    case "$source_path" in
        */.gh-pr-enrich-install.*/claim/gh-pr-enrich)
            /bin/ln -s "$NEWER_REGISTRATION_SOURCE" \
                "$CONCURRENT_CODEX_TARGET" || exit 78
            exec /bin/ln "$@"
            ;;
    esac
    /bin/ln "$@" || exit $?
    payload=$(/usr/bin/readlink "$CONCURRENT_CODEX_TARGET") || exit 74
    replacement="$CONCURRENT_CODEX_TARGET.concurrent"
    /bin/ln -s "$payload" "$replacement" || exit 75
    /bin/rm "$CONCURRENT_CODEX_TARGET" || exit 76
    /bin/mv "$replacement" "$CONCURRENT_CODEX_TARGET" || exit 77
    exit 0
fi
if [ "$published_path" = "$FAIL_CLAUDE_INSTALL_TARGET" ]; then
    exit 73
fi
exec /bin/ln "$@"
STUB
chmod +x "$RESTORE_RACE_STUBS/ln"
rc=0
RESTORE_RACE_OUTPUT=$(env HOME="$TEST_HOME" \
    FAIL_CLAUDE_INSTALL_TARGET="$CLAUDE_SKILL" \
    CONCURRENT_CODEX_TARGET="$CODEX_SKILL" \
    NEWER_REGISTRATION_SOURCE="$NEWER_REGISTRATION_SOURCE" \
    PATH="$RESTORE_RACE_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill 2>&1) || rc=$?
RESTORE_RACE_CLAIMED=$(find "$TEST_HOME/.codex/skills" \
    -path '*/.gh-pr-enrich-install.*/claim/gh-pr-enrich' \
    -type l -print -quit)
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a restore-boundary replacement fails the transactional install"
assert_eq "$NEWER_REGISTRATION_SOURCE" "$(readlink "$CODEX_SKILL")" \
    "restore rollback never overwrites a newer public Codex registration"
assert_true "$([ -L "$RESTORE_RACE_CLAIMED" ] && echo 0 || echo 1)" \
    "the displaced concurrent registration remains recoverable"
assert_eq "$(dirname "$CANONICAL_SKILL")" \
    "$(readlink "$RESTORE_RACE_CLAIMED")" \
    "the recoverable claim retains the displaced registration payload"
assert_contains "$RESTORE_RACE_OUTPUT" "preserved at" \
    "restore collision reports the recoverable registration path"
rm "$CODEX_SKILL" "$RESTORE_RACE_CLAIMED"
rmdir "$(dirname "$RESTORE_RACE_CLAIMED")"
rmdir "$(dirname "$(dirname "$RESTORE_RACE_CLAIMED")")"

# Transaction-scoped signal handling cleans private references and never
# leaves only one runtime registered.
PRIVATE_SIGNAL_STUBS="$TEST_OUTPUT_DIR/private-signal-stubs"
mkdir -p "$PRIVATE_SIGNAL_STUBS"
cat > "$PRIVATE_SIGNAL_STUBS/ln" << 'STUB'
#!/bin/bash
target="${!#}"
case "$target" in
    */.gh-pr-enrich-install.*/gh-pr-enrich)
        /bin/ln "$@" || exit $?
        kill -INT "$PPID"
        exit 73
        ;;
esac
exec /bin/ln "$@"
STUB
chmod +x "$PRIVATE_SIGNAL_STUBS/ln"
rc=0
env HOME="$TEST_HOME" PATH="$PRIVATE_SIGNAL_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill >/dev/null 2>&1 || rc=$?
assert_eq "130" "$rc" \
    "INT after private reference creation preserves the conventional status"
assert_true "$([ ! -L "$CODEX_SKILL" ] && [ ! -L "$CLAUDE_SKILL" ] && echo 0 || echo 1)" \
    "private-reference cancellation leaves no partial runtime registration"
assert_no_skill_install_residue \
    "private-reference cancellation removes its ownership reference"

PUBLISHED_SIGNAL_STUBS="$TEST_OUTPUT_DIR/published-signal-stubs"
mkdir -p "$PUBLISHED_SIGNAL_STUBS"
cat > "$PUBLISHED_SIGNAL_STUBS/ln" << 'STUB'
#!/bin/bash
target="${!#}"
source_index=$(( $# - 1 ))
source_path="${!source_index}"
published_path="$target/$(basename "$source_path")"
if [ "$published_path" = "$SIGNAL_CODEX_TARGET" ]; then
    /bin/ln "$@" || exit $?
    kill -TERM "$PPID"
    exit 73
fi
exec /bin/ln "$@"
STUB
chmod +x "$PUBLISHED_SIGNAL_STUBS/ln"
rc=0
env HOME="$TEST_HOME" SIGNAL_CODEX_TARGET="$CODEX_SKILL" \
    PATH="$PUBLISHED_SIGNAL_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill >/dev/null 2>&1 || rc=$?
assert_eq "143" "$rc" \
    "TERM after Codex publication preserves the conventional status"
assert_true "$([ ! -L "$CODEX_SKILL" ] && [ ! -L "$CLAUDE_SKILL" ] && echo 0 || echo 1)" \
    "post-publication cancellation rolls back the partial registration"
assert_no_skill_install_residue \
    "post-publication cancellation removes its ownership reference"

CLAUDE_SIGNAL_STUBS="$TEST_OUTPUT_DIR/claude-signal-stubs"
mkdir -p "$CLAUDE_SIGNAL_STUBS"
cat > "$CLAUDE_SIGNAL_STUBS/ln" << 'STUB'
#!/bin/bash
target="${!#}"
source_index=$(( $# - 1 ))
source_path="${!source_index}"
published_path="$target/$(basename "$source_path")"
if [ "$published_path" = "$SIGNAL_CLAUDE_TARGET" ]; then
    /bin/ln "$@" || exit $?
    kill -INT "$PPID"
    exit 73
fi
exec /bin/ln "$@"
STUB
chmod +x "$CLAUDE_SIGNAL_STUBS/ln"
rc=0
env HOME="$TEST_HOME" SIGNAL_CLAUDE_TARGET="$CLAUDE_SKILL" \
    PATH="$CLAUDE_SIGNAL_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill >/dev/null 2>&1 || rc=$?
assert_eq "130" "$rc" \
    "INT during Claude installation preserves the conventional status"
assert_true "$([ ! -L "$CODEX_SKILL" ] && [ ! -L "$CLAUDE_SKILL" ] && echo 0 || echo 1)" \
    "Claude-install cancellation rolls back the partial registration"
assert_no_skill_install_residue \
    "Claude-install cancellation removes its ownership reference"

CLAUDE_PRECOMMIT_SIGNAL_STUBS="$TEST_OUTPUT_DIR/claude-precommit-signal-stubs"
mkdir -p "$CLAUDE_PRECOMMIT_SIGNAL_STUBS"
cat > "$CLAUDE_PRECOMMIT_SIGNAL_STUBS/ln" << 'STUB'
#!/bin/bash
target="${!#}"
source_index=$(( $# - 1 ))
source_path="${!source_index}"
published_path="$target/$(basename "$source_path")"
if [ "$published_path" = "$SIGNAL_CLAUDE_TARGET" ]; then
    /bin/ln "$@" || exit $?
    kill -TERM "$PPID"
    exit 0
fi
exec /bin/ln "$@"
STUB
chmod +x "$CLAUDE_PRECOMMIT_SIGNAL_STUBS/ln"
rc=0
env HOME="$TEST_HOME" SIGNAL_CLAUDE_TARGET="$CLAUDE_SKILL" \
    PATH="$CLAUDE_PRECOMMIT_SIGNAL_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill >/dev/null 2>&1 || rc=$?
assert_eq "143" "$rc" \
    "TERM after both publications preserves the conventional status"
assert_true "$([ ! -L "$CODEX_SKILL" ] && [ ! -L "$CLAUDE_SKILL" ] && echo 0 || echo 1)" \
    "pre-commit cancellation rolls back both runtime registrations"
assert_no_skill_install_residue \
    "pre-commit cancellation removes both ownership references"

# Once both public registrations pass commit revalidation, cancellation during
# private-reference cleanup preserves the coherent pair and removes residue.
POST_COMMIT_SIGNAL_STUBS="$TEST_OUTPUT_DIR/post-commit-signal-stubs"
mkdir -p "$POST_COMMIT_SIGNAL_STUBS"
cat > "$POST_COMMIT_SIGNAL_STUBS/rm" << 'STUB'
#!/bin/bash
target="${!#}"
case "$target" in
    */.gh-pr-enrich-install.*/gh-pr-enrich)
        /bin/rm "$@" || exit $?
        kill -TERM "$PPID"
        exit 0
        ;;
esac
exec /bin/rm "$@"
STUB
chmod +x "$POST_COMMIT_SIGNAL_STUBS/rm"
rc=0
env HOME="$TEST_HOME" PATH="$POST_COMMIT_SIGNAL_STUBS:$PATH" \
    "$GH_PR_ENRICH" install-skill >/dev/null 2>&1 || rc=$?
assert_eq "143" "$rc" \
    "TERM after commit revalidation preserves the conventional status"
assert_true "$([ -L "$CODEX_SKILL" ] && [ -L "$CLAUDE_SKILL" ] && echo 0 || echo 1)" \
    "post-commit cancellation preserves the coherent two-runtime install"
assert_no_skill_install_residue \
    "post-commit cancellation removes both ownership references"
HOME="$TEST_HOME" "$GH_PR_ENRICH" uninstall-skill >/dev/null

# ---------------------------------------------------------------------------
# End-to-end stubs
# ---------------------------------------------------------------------------
cat > "$STUB_DIR/gh" << 'STUB'
#!/bin/bash
case "$1 $2" in
    "repo view")
        if [ -n "${PARENT_CAPTURE_SIGNAL_READY:-}" ]; then
            printf '%s\n' "$$" > "$PARENT_CAPTURE_SIGNAL_CHILD_PID_FILE"
            : > "$PARENT_CAPTURE_SIGNAL_READY"
            trap '' TERM INT
            while true; do sleep 0.05; done
        fi
        explicit_repository=false
        source_repository="o/r"
        case "${3:-}" in
            ""|--*) ;;
            *) explicit_repository=true; source_repository="$3" ;;
        esac
        if [ "$explicit_repository" = true ]; then
            [ -z "${VISIBILITY_QUERY_LOG:-}" ] || \
                printf '%s\n' "$source_repository" >> "$VISIBILITY_QUERY_LOG"
            [ "${LIVE_VISIBILITY_QUERY_FAIL_REPO:-}" != "$source_repository" ] || \
                exit 1
        fi
        case "$source_repository" in
            o/r)
                source_visibility="${REPO_VISIBILITY:-PUBLIC}"
                [ "$explicit_repository" != true ] || \
                    source_visibility="${LIVE_REPO_VISIBILITY:-$source_visibility}"
                ;;
            intent/issues)
                source_visibility="${LIVE_LINKED_ISSUE_VISIBILITY:-${LINKED_ISSUE_VISIBILITY:-PUBLIC}}"
                ;;
            *) source_visibility="UNKNOWN" ;;
        esac
        case "$*" in
            *id,nameWithOwner,visibility*) printf '{"id":"%s","nameWithOwner":"%s","visibility":"%s"}\n' \
                "${REPO_ID:-REPO_o_r}" "$source_repository" "$source_visibility" ;;
            *visibility*) echo "$source_visibility" ;;
            *) echo "$source_repository" ;;
        esac
        exit 0
        ;;
    "pr view")
        if [ -n "${MUTATE_ANALYSIS_SOURCE:-}" ] && [ -f "$MUTATE_ANALYSIS_SOURCE" ]; then
            jq '.process_improvements[0].suggestion = "mutated after selector freeze"' \
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
 "baseRefOid":"${PR_BASE_OID:-base123}","baseRefName":"${PR_BASE_REF_NAME:-main}",
 "files":[{"path":"gh-pr-enrich","additions":1,"deletions":0}],"commits":[],
 "labels":[],"assignees":[],"reviews":[]}
JSON
        exit 0
        ;;
    "pr checks") echo '[]'; exit 0 ;;
    "pr diff")
        printf 'diff --git a/gh-pr-enrich b/gh-pr-enrich\n--- a/gh-pr-enrich\n+++ b/gh-pr-enrich\n@@ -0,0 +1 @@\n+example\n'
        exit 0
        ;;
esac
if [ "$1" = "api" ] && [ -n "${PARENT_CAPTURE_STATE_SIGNAL_READY:-}" ]; then
    printf '%s\n' "$$" > "$PARENT_CAPTURE_STATE_SIGNAL_CHILD_PID_FILE"
    : > "$PARENT_CAPTURE_STATE_SIGNAL_READY"
    trap '' TERM INT
    while true; do sleep 0.05; done
fi
if [ "$1" = "api" ] && [ "$2" = "graphql" ]; then
    case "$*" in
        *ExternalDisclosureVisibility*)
            [ -z "${VISIBILITY_QUERY_ARGS_LOG:-}" ] || \
                printf '%s\n' "$*" > "$VISIBILITY_QUERY_ARGS_LOG"
            if [ -n "${VISIBILITY_SIGNAL_READY:-}" ]; then
                printf '%s\n' "$$" > "$VISIBILITY_SIGNAL_CHILD_PID_FILE"
                : > "$VISIBILITY_SIGNAL_READY"
                trap '' TERM INT
                /bin/sleep 0.2
                kill -"$VISIBILITY_SIGNAL" "$PPID"
                while true; do sleep 0.05; done
            fi
            [ "${LIVE_VISIBILITY_QUERY_FAIL_REPO:-}" != "o/r" ] || exit 1
            [ "${LIVE_VISIBILITY_QUERY_FAIL_REPO:-}" != "intent/issues" ] || exit 1
            [ -z "${VISIBILITY_QUERY_LOG:-}" ] || printf 'o/r\n' >> "$VISIBILITY_QUERY_LOG"
            if [ -n "${LINKED_ISSUE_VISIBILITY:-}" ]; then
                live_linked_repository="${LIVE_LINKED_ISSUE_REPOSITORY:-intent/issues}"
                live_linked_visibility="${LIVE_LINKED_ISSUE_VISIBILITY:-$LINKED_ISSUE_VISIBILITY}"
                [ -z "${VISIBILITY_QUERY_LOG:-}" ] || \
                    printf '%s\n' "$live_linked_repository" >> "$VISIBILITY_QUERY_LOG"
                printf '{"data":{"primaryRepository":{"id":"%s","nameWithOwner":"o/r","visibility":"%s"},"nodes":[{"id":"ISSUE_linked","repository":{"nameWithOwner":"%s","visibility":"%s"}}]}}\n' \
                    "${LIVE_REPO_ID:-${REPO_ID:-REPO_o_r}}" \
                    "${LIVE_REPO_VISIBILITY:-${REPO_VISIBILITY:-PUBLIC}}" \
                    "$live_linked_repository" "$live_linked_visibility"
            else
                printf '{"data":{"primaryRepository":{"id":"%s","nameWithOwner":"o/r","visibility":"%s"},"nodes":[]}}\n' \
                    "${LIVE_REPO_ID:-${REPO_ID:-REPO_o_r}}" \
                    "${LIVE_REPO_VISIBILITY:-${REPO_VISIBILITY:-PUBLIC}}"
            fi
            ;;
        *closingIssuesReferences*)
            live_intent_title="${LIVE_INTENT_TITLE:-t}"
            live_intent_body="${LIVE_INTENT_BODY:-b}"
            if [ -n "${LINKED_ISSUE_VISIBILITY:-}" ]; then
                printf '{"data":{"repository":{"pullRequest":{"number":1,"title":"%s","body":"%s","closingIssuesReferences":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"ISSUE_linked","number":42,"title":"linked intent","body":"linked repository secret","url":"https://github.com/intent/issues/42","repository":{"nameWithOwner":"intent/issues","visibility":"%s"}}]}}}}}\n' \
                    "$live_intent_title" "$live_intent_body" \
                    "$LINKED_ISSUE_VISIBILITY"
            else
                printf '{"data":{"repository":{"pullRequest":{"number":1,"title":"%s","body":"%s","closingIssuesReferences":{"totalCount":0,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}}\n' \
                    "$live_intent_title" "$live_intent_body"
            fi
            ;;
        *) echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"PRRT_open","isResolved":false,"isOutdated":false,"path":"a.js","line":1,"comments":{"totalCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"c","databaseId":1,"body":"check this","author":{"login":"rev"},"createdAt":"2026-01-01T00:00:00Z","url":"https://github.com/o/r/pull/1#discussion_r1"}]}}]}}}}}' ;;
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
[ -z "${CLAUDE_STUB_EXIT_CODE:-}" ] || exit "$CLAUDE_STUB_EXIT_CODE"
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

# Startup and watch-mode repository discovery happen before a report lease
# exists. A signal sent only to the advertised CLI PID must still terminate the
# parent-owned capture supervisor and its TERM-ignoring GitHub request.
for PARENT_CAPTURE_MODE in main watch; do
    case "$PARENT_CAPTURE_MODE" in
        main)
            PARENT_CAPTURE_SIGNAL=TERM
            PARENT_CAPTURE_EXPECTED_RC=143
            PARENT_CAPTURE_ARGS=(1 --output-dir \
                "$TEST_OUTPUT_DIR/parent-capture-main-report")
            ;;
        watch)
            PARENT_CAPTURE_SIGNAL=TERM
            PARENT_CAPTURE_EXPECTED_RC=143
            PARENT_CAPTURE_ARGS=(watch 1 --interval 1)
            ;;
    esac
    PARENT_CAPTURE_CASE_DIR="$TEST_OUTPUT_DIR/parent-capture-$PARENT_CAPTURE_MODE"
    PARENT_CAPTURE_READY="$PARENT_CAPTURE_CASE_DIR/ready"
    PARENT_CAPTURE_CHILD_PID_FILE="$PARENT_CAPTURE_CASE_DIR/child-pid"
    PARENT_CAPTURE_SUPERVISOR_PID_FILE="$PARENT_CAPTURE_CASE_DIR/supervisor-pid"
    PARENT_CAPTURE_OUT="$PARENT_CAPTURE_CASE_DIR/output.txt"
    PARENT_CAPTURE_TMP="$PARENT_CAPTURE_CASE_DIR/tmp"
    mkdir -p "$PARENT_CAPTURE_TMP"
    env PATH="$STUB_DIR:$PATH" TMPDIR="$PARENT_CAPTURE_TMP" \
        GH_PR_ENRICH_GITHUB_TIMEOUT=20 \
        GH_PR_ENRICH_DEBUG_PARENT_CAPTURE_PID_FILE="$PARENT_CAPTURE_SUPERVISOR_PID_FILE" \
        PARENT_CAPTURE_SIGNAL_READY="$PARENT_CAPTURE_READY" \
        PARENT_CAPTURE_SIGNAL_CHILD_PID_FILE="$PARENT_CAPTURE_CHILD_PID_FILE" \
        "$GH_PR_ENRICH" "${PARENT_CAPTURE_ARGS[@]}" \
        > "$PARENT_CAPTURE_OUT" 2>&1 &
    PARENT_CAPTURE_CLI_PID=$!
    for (( _capture_wait=0; _capture_wait < 100; _capture_wait++ )); do
        [ ! -e "$PARENT_CAPTURE_READY" ] || break
        sleep 0.05
    done
    kill -"$PARENT_CAPTURE_SIGNAL" "$PARENT_CAPTURE_CLI_PID" 2>/dev/null || true
    rc=0
    wait "$PARENT_CAPTURE_CLI_PID" || rc=$?
    assert_true "$([ -e "$PARENT_CAPTURE_READY" ] && echo 0 || echo 1)" \
        "$PARENT_CAPTURE_MODE startup cancellation fixture reaches repository discovery"
    assert_eq "$PARENT_CAPTURE_EXPECTED_RC" "$rc" \
        "$PARENT_CAPTURE_SIGNAL sent to the $PARENT_CAPTURE_MODE CLI PID preserves conventional status"
    PARENT_CAPTURE_CHILD_PID=$(cat \
        "$PARENT_CAPTURE_CHILD_PID_FILE" 2>/dev/null || echo "")
    PARENT_CAPTURE_SUPERVISOR_PID=$(tail -1 \
        "$PARENT_CAPTURE_SUPERVISOR_PID_FILE" 2>/dev/null || echo "")
    assert_process_reaped "$PARENT_CAPTURE_CHILD_PID" \
        "$PARENT_CAPTURE_MODE startup cancellation reaps the GitHub request"
    assert_process_reaped "$PARENT_CAPTURE_SUPERVISOR_PID" \
        "$PARENT_CAPTURE_MODE startup cancellation reaps the capture supervisor"
    PARENT_CAPTURE_RESIDUE=$(find "$PARENT_CAPTURE_TMP" \
        \( -name 'gh-pr-enrich-prelock-output.*' -o \
           -name 'gh-pr-enrich-parent-capture.*' \) -print -quit)
    assert_true "$([ -z "$PARENT_CAPTURE_RESIDUE" ] && echo 0 || echo 1)" \
        "$PARENT_CAPTURE_MODE startup cancellation removes capture staging"
done

PARENT_CAPTURE_STOPPED_DIR="$TEST_OUTPUT_DIR/parent-capture-stopped-supervisor"
PARENT_CAPTURE_STOPPED_READY="$PARENT_CAPTURE_STOPPED_DIR/ready"
PARENT_CAPTURE_STOPPED_CHILD_PID_FILE="$PARENT_CAPTURE_STOPPED_DIR/child-pid"
PARENT_CAPTURE_STOPPED_SUPERVISOR_PID_FILE="$PARENT_CAPTURE_STOPPED_DIR/supervisor-pid"
PARENT_CAPTURE_STOPPED_OUT="$PARENT_CAPTURE_STOPPED_DIR/output.txt"
PARENT_CAPTURE_STOPPED_TMP="$PARENT_CAPTURE_STOPPED_DIR/tmp"
mkdir -p "$PARENT_CAPTURE_STOPPED_TMP"
env PATH="$STUB_DIR:$PATH" TMPDIR="$PARENT_CAPTURE_STOPPED_TMP" \
    GH_PR_ENRICH_GITHUB_TIMEOUT=20 \
    GH_PR_ENRICH_DEBUG_PARENT_CAPTURE_PID_FILE="$PARENT_CAPTURE_STOPPED_SUPERVISOR_PID_FILE" \
    PARENT_CAPTURE_SIGNAL_READY="$PARENT_CAPTURE_STOPPED_READY" \
    PARENT_CAPTURE_SIGNAL_CHILD_PID_FILE="$PARENT_CAPTURE_STOPPED_CHILD_PID_FILE" \
    "$GH_PR_ENRICH" 1 --output-dir \
        "$TEST_OUTPUT_DIR/parent-capture-stopped-report" \
    > "$PARENT_CAPTURE_STOPPED_OUT" 2>&1 &
PARENT_CAPTURE_STOPPED_CLI_PID=$!
for (( _capture_wait=0; _capture_wait < 100; _capture_wait++ )); do
    [ -e "$PARENT_CAPTURE_STOPPED_READY" ] && \
        find "$PARENT_CAPTURE_STOPPED_TMP" -name active-child \
            -print -quit | grep -q . && break
    sleep 0.05
done
PARENT_CAPTURE_STOPPED_SUPERVISOR_PID=$(tail -1 \
    "$PARENT_CAPTURE_STOPPED_SUPERVISOR_PID_FILE" 2>/dev/null || echo "")
[ -z "$PARENT_CAPTURE_STOPPED_SUPERVISOR_PID" ] || \
    kill -STOP -- "-$PARENT_CAPTURE_STOPPED_SUPERVISOR_PID" 2>/dev/null || true
kill -TERM "$PARENT_CAPTURE_STOPPED_CLI_PID" 2>/dev/null || true
rc=0
wait "$PARENT_CAPTURE_STOPPED_CLI_PID" || rc=$?
assert_true "$([ -e "$PARENT_CAPTURE_STOPPED_READY" ] && echo 0 || echo 1)" \
    "stopped-supervisor fixture reaches the nested GitHub request"
assert_eq "143" "$rc" \
    "TERM with a stopped capture supervisor preserves conventional status"
PARENT_CAPTURE_STOPPED_CHILD_PID=$(cat \
    "$PARENT_CAPTURE_STOPPED_CHILD_PID_FILE" 2>/dev/null || echo "")
assert_true "$([ -n "$PARENT_CAPTURE_STOPPED_CHILD_PID" ] && \
    ! kill -0 "$PARENT_CAPTURE_STOPPED_CHILD_PID" 2>/dev/null && echo 0 || echo 1)" \
    "stopped-supervisor fallback reaps the independent GitHub request before return"
assert_true "$([ -n "$PARENT_CAPTURE_STOPPED_SUPERVISOR_PID" ] && \
    ! kill -0 "$PARENT_CAPTURE_STOPPED_SUPERVISOR_PID" 2>/dev/null && echo 0 || echo 1)" \
    "stopped-supervisor fallback reaps the capture supervisor before return"
PARENT_CAPTURE_STOPPED_RESIDUE=$(find "$PARENT_CAPTURE_STOPPED_TMP" \
    \( -name 'gh-pr-enrich-prelock-output.*' -o \
       -name 'gh-pr-enrich-parent-capture.*' \) -print -quit)
assert_true "$([ -z "$PARENT_CAPTURE_STOPPED_RESIDUE" ] && echo 0 || echo 1)" \
    "stopped-supervisor fallback removes every capture staging artifact"

PARENT_CAPTURE_STATE_DIR="$TEST_OUTPUT_DIR/parent-capture-watch-state"
PARENT_CAPTURE_STATE_READY="$PARENT_CAPTURE_STATE_DIR/ready"
PARENT_CAPTURE_STATE_CHILD_PID_FILE="$PARENT_CAPTURE_STATE_DIR/child-pid"
PARENT_CAPTURE_STATE_SUPERVISOR_PID_FILE="$PARENT_CAPTURE_STATE_DIR/supervisor-pids"
PARENT_CAPTURE_STATE_OUT="$PARENT_CAPTURE_STATE_DIR/output.txt"
PARENT_CAPTURE_STATE_TMP="$PARENT_CAPTURE_STATE_DIR/tmp"
mkdir -p "$PARENT_CAPTURE_STATE_TMP"
env PATH="$STUB_DIR:$PATH" TMPDIR="$PARENT_CAPTURE_STATE_TMP" \
    GH_PR_ENRICH_GITHUB_TIMEOUT=20 \
    GH_PR_ENRICH_DEBUG_PARENT_CAPTURE_PID_FILE="$PARENT_CAPTURE_STATE_SUPERVISOR_PID_FILE" \
    PARENT_CAPTURE_STATE_SIGNAL_READY="$PARENT_CAPTURE_STATE_READY" \
    PARENT_CAPTURE_STATE_SIGNAL_CHILD_PID_FILE="$PARENT_CAPTURE_STATE_CHILD_PID_FILE" \
    "$GH_PR_ENRICH" watch 1 --interval 1 \
    > "$PARENT_CAPTURE_STATE_OUT" 2>&1 &
PARENT_CAPTURE_STATE_CLI_PID=$!
for (( _capture_wait=0; _capture_wait < 100; _capture_wait++ )); do
    [ ! -e "$PARENT_CAPTURE_STATE_READY" ] || break
    sleep 0.05
done
kill -TERM "$PARENT_CAPTURE_STATE_CLI_PID" 2>/dev/null || true
rc=0
wait "$PARENT_CAPTURE_STATE_CLI_PID" || rc=$?
assert_true "$([ -e "$PARENT_CAPTURE_STATE_READY" ] && echo 0 || echo 1)" \
    "watch-state cancellation fixture reaches a nested GitHub request"
assert_eq "143" "$rc" \
    "TERM during initial watch-state capture preserves conventional status"
PARENT_CAPTURE_STATE_CHILD_PID=$(cat \
    "$PARENT_CAPTURE_STATE_CHILD_PID_FILE" 2>/dev/null || echo "")
PARENT_CAPTURE_STATE_SUPERVISOR_PID=$(tail -1 \
    "$PARENT_CAPTURE_STATE_SUPERVISOR_PID_FILE" 2>/dev/null || echo "")
assert_true "$([ -n "$PARENT_CAPTURE_STATE_CHILD_PID" ] && \
    ! kill -0 "$PARENT_CAPTURE_STATE_CHILD_PID" 2>/dev/null && echo 0 || echo 1)" \
    "watch-state cancellation reaps the nested GitHub request before the CLI returns"
assert_true "$([ -n "$PARENT_CAPTURE_STATE_SUPERVISOR_PID" ] && \
    ! kill -0 "$PARENT_CAPTURE_STATE_SUPERVISOR_PID" 2>/dev/null && echo 0 || echo 1)" \
    "watch-state cancellation reaps the capture supervisor before the CLI returns"
PARENT_CAPTURE_STATE_RESIDUE=$(find "$PARENT_CAPTURE_STATE_TMP" \
    \( -name 'gh-pr-enrich-prelock-output.*' -o \
       -name 'gh-pr-enrich-parent-capture.*' \) -print -quit)
assert_true "$([ -z "$PARENT_CAPTURE_STATE_RESIDUE" ] && echo 0 || echo 1)" \
    "watch-state cancellation removes capture staging"

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
for (( _wait_attempt=0; _wait_attempt < 200; _wait_attempt++ )); do
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
    "the lock owner completes after the concurrent run is rejected" \
    "$(tail -20 "$COLLECTION_LOCK_FIRST_OUT" 2>/dev/null || true)"
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
for (( _wait_attempt=0; _wait_attempt < 200; _wait_attempt++ )); do
    [ -e "$COLLECTION_ACQUIRE_READY" ] && break
    sleep 0.05
done
assert_true "$([ -e "$COLLECTION_ACQUIRE_READY" ] && echo 0 || echo 1)" \
    "the acquisition fixture reaches the owner-publication window"
kill -TERM "$RUNTIME_BACKGROUND_PID" 2>/dev/null || true
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
for (( _wait_attempt=0; _wait_attempt < 200; _wait_attempt++ )); do
    [ ! -e "$COLLECTION_SIGNAL_READY" ] || break
    sleep 0.05
done
assert_true "$([ -e "$COLLECTION_SIGNAL_READY" ] && echo 0 || echo 1)" \
    "the signal fixture reaches collection while holding the report lock"
kill -TERM "$RUNTIME_BACKGROUND_PID"
for (( _wait_attempt=0; _wait_attempt < 200; _wait_attempt++ )); do
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
       [ -d "$CHILD_START_REPORT/.selected-analysis.lock" ] && \
       [ ! -e "$CHILD_START_HOOK_MARKER" ]; then
        : > "$CHILD_START_HOOK_MARKER"
        for (( _child_start_wait=0; _child_start_wait < 200; _child_start_wait++ )); do
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
    CHILD_START_REPORT="$CHILD_START_REPORT" \
    CHILD_START_PID_FILE="$CHILD_START_PID_FILE" \
    CHILD_START_HOOK_MARKER="$CHILD_START_HOOK_MARKER" \
    "$GH_PR_ENRICH" 1 --output-dir "$CHILD_START_REPORT" \
    >/dev/null 2>&1 &
RUNTIME_BACKGROUND_PID=$!
for (( _wait_attempt=0; _wait_attempt < 200; _wait_attempt++ )); do
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

# The request watchdog has its own fork-to-PID-publication boundary. A signal
# at that exact DEBUG hook must wait for the watchdog PID, then reap both the
# GitHub child and watchdog before releasing the report lease.
REPORT_WATCHDOG_STUBS="$TEST_OUTPUT_DIR/report-watchdog-stubs"
REPORT_WATCHDOG_REPORT="$TEST_OUTPUT_DIR/report-watchdog-report"
REPORT_WATCHDOG_CHILD_PID_FILE="$TEST_OUTPUT_DIR/report-watchdog-child.pid"
REPORT_WATCHDOG_PID_FILE="$TEST_OUTPUT_DIR/report-watchdog.pid"
REPORT_WATCHDOG_BASH_ENV="$TEST_OUTPUT_DIR/report-watchdog-bash-env"
REPORT_WATCHDOG_MARKER="$TEST_OUTPUT_DIR/report-watchdog-hook-fired"
mkdir -p "$REPORT_WATCHDOG_STUBS"
cat > "$REPORT_WATCHDOG_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr view" ]; then
    printf '%s\n' "$$" > "$REPORT_WATCHDOG_CHILD_PID_FILE"
    trap '' TERM INT
    while true; do sleep 0.05; done
fi
exec "$REPORT_WATCHDOG_BASE_GH" "$@"
STUB
cat > "$REPORT_WATCHDOG_BASH_ENV" << 'STUB'
__gh_pr_enrich_report_watchdog_debug() {
    if [ "$BASH_COMMAND" = 'REPORT_RUN_WATCHDOG_PID=$!' ] && \
       [ -d "$REPORT_WATCHDOG_REPORT/.selected-analysis.lock" ] && \
       [ ! -e "$REPORT_WATCHDOG_MARKER" ]; then
        printf '%s\n' "$!" > "$REPORT_WATCHDOG_PID_FILE"
        : > "$REPORT_WATCHDOG_MARKER"
        kill -TERM "$$"
    fi
}
set -T
trap '__gh_pr_enrich_report_watchdog_debug' DEBUG
STUB
chmod +x "$REPORT_WATCHDOG_STUBS/gh"
rc=0
env PATH="$REPORT_WATCHDOG_STUBS:$STUB_DIR:$PATH" \
    BASH_ENV="$REPORT_WATCHDOG_BASH_ENV" \
    REPORT_WATCHDOG_BASE_GH="$STUB_DIR/gh" \
    REPORT_WATCHDOG_REPORT="$REPORT_WATCHDOG_REPORT" \
    REPORT_WATCHDOG_CHILD_PID_FILE="$REPORT_WATCHDOG_CHILD_PID_FILE" \
    REPORT_WATCHDOG_PID_FILE="$REPORT_WATCHDOG_PID_FILE" \
    REPORT_WATCHDOG_MARKER="$REPORT_WATCHDOG_MARKER" \
    GH_PR_ENRICH_GITHUB_TIMEOUT=1 \
    "$GH_PR_ENRICH" 1 --output-dir "$REPORT_WATCHDOG_REPORT" \
    >/dev/null 2>&1 || rc=$?
assert_true "$([ -e "$REPORT_WATCHDOG_MARKER" ] && echo 0 || echo 1)" \
    "the report watchdog regression signals at the PID-publication boundary"
assert_eq "143" "$rc" \
    "a signal during report watchdog publication is deferred then honored"
REPORT_WATCHDOG_CHILD_PID=$(cat "$REPORT_WATCHDOG_CHILD_PID_FILE")
REPORT_WATCHDOG_PID=$(cat "$REPORT_WATCHDOG_PID_FILE")
assert_process_reaped "$REPORT_WATCHDOG_CHILD_PID" \
    "watchdog-publication cancellation reaps the GitHub child"
assert_process_reaped "$REPORT_WATCHDOG_PID" \
    "watchdog-publication cancellation reaps the timeout watcher"
assert_true "$([ ! -e "$REPORT_WATCHDOG_REPORT/.selected-analysis.lock" ] && \
    echo 0 || echo 1)" \
    "watchdog-publication cancellation releases the report lease"
REPORT_WATCHDOG_CHILD_PID_FILE=""
REPORT_WATCHDOG_PID_FILE=""

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
for (( _wait_attempt=0; _wait_attempt < 200; _wait_attempt++ )); do
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
for (( _wait_attempt=0; _wait_attempt < 200; _wait_attempt++ )); do
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
mkdir "$STALE_LINKED_REPORT/.pr-summary-connections.Q1w2E3"
printf '[]\n' > "$STALE_LINKED_REPORT/.pr-summary-connections.Q1w2E3/files.json"
printf '{}\n' > "$STALE_LINKED_REPORT/.pr-summary-connections.Q1w2E3/pr-summary.json"
env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" 1 \
    --output-dir "$STALE_LINKED_REPORT" >/dev/null 2>&1
STALE_LINKED_RESIDUE=$(find "$STALE_LINKED_REPORT" -maxdepth 2 \
    \( -name 'linked-issues.json.pages.*' -o \
       -name 'linked-issues.json.normalized.*' -o \
       -name '.pr-summary-connections.*' \) -print -quit)
assert_true "$([ -z "$STALE_LINKED_RESIDUE" ] && echo 0 || echo 1)" \
    "a new lock owner recovers linked and PR-summary pagination staging from a crashed run"

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
rc=0
env PATH="$STUB_DIR:$PATH" PR_BASE_OID=retargeted-base \
    "$GH_PR_ENRICH" --test-call verify_pr_head_unchanged \
        1 abc123 "" base123 main >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "hosted revision revalidation detects a same-head base advance"
rc=0
env PATH="$STUB_DIR:$PATH" PR_BASE_REF_NAME=release \
    "$GH_PR_ENRICH" --test-call verify_pr_head_unchanged \
        1 abc123 "" base123 main >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "hosted revision revalidation detects a same-commit base retarget"

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

NEWLINE_OUTPUT_DIR="$TEST_OUTPUT_DIR/newline-output"
mkdir -p "$NEWLINE_OUTPUT_DIR"
printf '%s\n' "local secret" > \
    "$NEWLINE_OUTPUT_DIR/"$'analysis.json\ncombined-data.json'
rc=0
NEWLINE_OUTPUT_OUT=$(env PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" 1 \
    --output-dir "$NEWLINE_OUTPUT_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "report preflight rejects a newline filename assembled from allowlisted fragments"
assert_contains "$NEWLINE_OUTPUT_OUT" "unrelated file" \
    "newline filename rejection is reported as unrelated output content"

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
PREPARED_DISCUSSION_FINGERPRINT=$("$GH_PR_ENRICH" --test-call \
    analysis_discussion_fingerprint_from_files "$PREPARED")
assert_jq "$PREPARED/analysis-context.json" \
    ".coverage.discussion.fingerprint == \"$PREPARED_DISCUSSION_FINGERPRINT\"" \
    "the context fingerprint binds the exact collected discussion snapshot"
PREPARED_INTENT_FINGERPRINT=$("$GH_PR_ENRICH" --test-call \
    analysis_intent_fingerprint_from_files "$PREPARED")
assert_jq "$PREPARED/analysis-context.json" \
    ".coverage.intent.fingerprint == \"$PREPARED_INTENT_FINGERPRINT\"" \
    "the context fingerprint binds mutable PR and linked-issue intent"
assert_not_contains "$PREP_OUT" "Claude analysis" \
    "context preparation does not invoke an external analyzer"

# A checks outage must not disable discussion revalidation. Make checks fail
# without usable state, then mutate issue comments between the two stabilized
# post-build discussion reads.
CHECKS_UNAVAILABLE_STUBS="$TEST_OUTPUT_DIR/checks-unavailable-stubs"
CHECKS_UNAVAILABLE_COUNT="$TEST_OUTPUT_DIR/checks-unavailable-discussion-count"
CHECKS_UNAVAILABLE_REPORT="$TEST_OUTPUT_DIR/checks-unavailable-report"
mkdir -p "$CHECKS_UNAVAILABLE_STUBS"
cat > "$CHECKS_UNAVAILABLE_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr checks" ]; then
    printf '[]\n'
    exit 1
fi
if [ "$1" = "api" ] && [ "$2" != "graphql" ]; then
    case "$*" in
        *repos/o/r/issues/1/comments*)
            count=$(cat "$CHECKS_UNAVAILABLE_COUNT" 2>/dev/null || echo 0)
            count=$((count + 1))
            printf '%s\n' "$count" > "$CHECKS_UNAVAILABLE_COUNT"
            if [ "$count" -ge 3 ]; then
                cat << 'JSON'
[{"id":99,"body":"changed after context build","user":{"login":"reviewer"},"created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","html_url":"https://github.com/o/r/pull/1#issuecomment-99"}]
JSON
            else
                printf '[]\n'
            fi
            exit 0
            ;;
    esac
fi
exec "$CHECKS_UNAVAILABLE_BASE_GH" "$@"
STUB
chmod +x "$CHECKS_UNAVAILABLE_STUBS/gh"
rc=0
CHECKS_UNAVAILABLE_OUT=$(env PATH="$CHECKS_UNAVAILABLE_STUBS:$STUB_DIR:$PATH" \
    CHECKS_UNAVAILABLE_COUNT="$CHECKS_UNAVAILABLE_COUNT" \
    CHECKS_UNAVAILABLE_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" 1 --prepare-analysis \
        --output-dir "$CHECKS_UNAVAILABLE_REPORT" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && \
    [ "$(cat "$CHECKS_UNAVAILABLE_COUNT" 2>/dev/null || echo 0)" -ge 3 ] && \
    echo 0 || echo 1)" \
    "failed checks coverage does not skip post-build discussion revalidation"
assert_jq "$CHECKS_UNAVAILABLE_REPORT/analysis-context.json" \
    '.coverage.sources.checks.status == "failed" and
     .coverage.checks.fingerprint == null' \
    "unavailable checks remain failed coverage without a trusted fingerprint"
assert_contains "$CHECKS_UNAVAILABLE_OUT" \
    "GitHub head, checks, discussion, or intent state changed or could not be revalidated" \
    "discussion drift still blocks context preparation when checks are unavailable"

# When only discussion identity is available, its fallback attestation still
# has to bracket the remote reads with the captured head. Advance the head
# during the stable discussion reads and prove the provider is never invoked.
CHECKS_UNAVAILABLE_HEAD_STUBS="$TEST_OUTPUT_DIR/checks-unavailable-head-stubs"
CHECKS_UNAVAILABLE_HEAD_COUNT="$TEST_OUTPUT_DIR/checks-unavailable-head-discussion-count"
CHECKS_UNAVAILABLE_HEAD_MARKER="$TEST_OUTPUT_DIR/checks-unavailable-head-drift"
CHECKS_UNAVAILABLE_HEAD_REPORT="$TEST_OUTPUT_DIR/checks-unavailable-head-report"
CHECKS_UNAVAILABLE_HEAD_CLAUDE_LOG="$TEST_OUTPUT_DIR/checks-unavailable-head-claude-invoked.txt"
mkdir -p "$CHECKS_UNAVAILABLE_HEAD_STUBS"
cat > "$CHECKS_UNAVAILABLE_HEAD_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr checks" ]; then
    printf '[]\n'
    exit 1
fi
if [ "$1 $2" = "pr view" ] && [ -e "$CHECKS_UNAVAILABLE_HEAD_MARKER" ]; then
    PR_HEAD_OID=new-hosted-head exec "$CHECKS_UNAVAILABLE_HEAD_BASE_GH" "$@"
fi
if [ "$1" = "api" ] && [ "$2" != "graphql" ]; then
    case "$*" in
        *repos/o/r/issues/1/comments*)
            count=$(cat "$CHECKS_UNAVAILABLE_HEAD_COUNT" 2>/dev/null || echo 0)
            count=$((count + 1))
            printf '%s\n' "$count" > "$CHECKS_UNAVAILABLE_HEAD_COUNT"
            [ "$count" -lt 2 ] || : > "$CHECKS_UNAVAILABLE_HEAD_MARKER"
            printf '[]\n'
            exit 0
            ;;
    esac
fi
exec "$CHECKS_UNAVAILABLE_HEAD_BASE_GH" "$@"
STUB
chmod +x "$CHECKS_UNAVAILABLE_HEAD_STUBS/gh"
rc=0
CHECKS_UNAVAILABLE_HEAD_OUT=$(env \
    PATH="$CHECKS_UNAVAILABLE_HEAD_STUBS:$STUB_DIR:$PATH" \
    CHECKS_UNAVAILABLE_HEAD_COUNT="$CHECKS_UNAVAILABLE_HEAD_COUNT" \
    CHECKS_UNAVAILABLE_HEAD_MARKER="$CHECKS_UNAVAILABLE_HEAD_MARKER" \
    CHECKS_UNAVAILABLE_HEAD_BASE_GH="$STUB_DIR/gh" \
    CLAUDE_INVOKED_LOG="$CHECKS_UNAVAILABLE_HEAD_CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --allow-external \
        --output-dir "$CHECKS_UNAVAILABLE_HEAD_REPORT" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ -e "$CHECKS_UNAVAILABLE_HEAD_MARKER" ] && \
    echo 0 || echo 1)" \
    "discussion-only fallback rejects a head advance during its remote reads" \
    "$CHECKS_UNAVAILABLE_HEAD_OUT"
assert_true "$([ ! -s "$CHECKS_UNAVAILABLE_HEAD_CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "partial hosted attestation blocks external invocation after head drift"
assert_jq "$CHECKS_UNAVAILABLE_HEAD_REPORT/analysis-context.json" \
    '.coverage.code_access.pr_head_sha == "abc123" and
     .coverage.sources.checks.status == "failed" and
     .coverage.checks.fingerprint == null' \
    "the blocked context remains bound to its original head and failed check coverage"
assert_contains "$CHECKS_UNAVAILABLE_HEAD_OUT" \
    "GitHub head, checks, discussion, or intent state changed or could not be revalidated" \
    "partial attestation head drift identifies the hosted-state boundary"

PRIVATE_LINKED_LOCAL_DIR="$TEST_OUTPUT_DIR/private-linked-local"
env PATH="$STUB_DIR:$PATH" REPO_VISIBILITY=PUBLIC \
    LINKED_ISSUE_VISIBILITY=PRIVATE \
    "$GH_PR_ENRICH" 1 --prepare-analysis \
    --output-dir "$PRIVATE_LINKED_LOCAL_DIR" >/dev/null 2>&1
assert_jq "$PRIVATE_LINKED_LOCAL_DIR/analysis-context.json" \
    '.pr.linked_issues[0]
     | .body == "linked repository secret" and
       .repository == {name_with_owner:"intent/issues",visibility:"PRIVATE"}' \
    "native analysis retains private cross-repository linked issue intent and visibility"

PRIVATE_LINKED_EXTERNAL_DIR="$TEST_OUTPUT_DIR/private-linked-external"
PRIVATE_LINKED_CLAUDE_LOG="$TEST_OUTPUT_DIR/private-linked-claude-invoked.txt"
rc=0
PRIVATE_LINKED_OUT=$(env PATH="$STUB_DIR:$PATH" REPO_VISIBILITY=PUBLIC \
    LINKED_ISSUE_VISIBILITY=PRIVATE \
    CLAUDE_INVOKED_LOG="$PRIVATE_LINKED_CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich \
    --output-dir "$PRIVATE_LINKED_EXTERNAL_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a public PR with a private linked issue fails the external disclosure gate"
assert_true "$([ ! -s "$PRIVATE_LINKED_CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "private cross-repository linked issue content is never sent to Claude implicitly"
assert_contains "$PRIVATE_LINKED_OUT" "Linked issue source visibility is PRIVATE" \
    "the cross-repository disclosure failure identifies the linked source visibility"
assert_jq "$PRIVATE_LINKED_EXTERNAL_DIR/linked-issues.json" \
    '.[0].body == "linked repository secret" and
     .[0].repository.visibility == "PRIVATE"' \
    "the blocked external run preserves private linked intent for local inspection"

UNKNOWN_LINKED_EXTERNAL_DIR="$TEST_OUTPUT_DIR/unknown-linked-external"
UNKNOWN_LINKED_CLAUDE_LOG="$TEST_OUTPUT_DIR/unknown-linked-claude-invoked.txt"
rc=0
UNKNOWN_LINKED_OUT=$(env PATH="$STUB_DIR:$PATH" REPO_VISIBILITY=PUBLIC \
    LINKED_ISSUE_VISIBILITY=UNKNOWN \
    CLAUDE_INVOKED_LOG="$UNKNOWN_LINKED_CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich \
    --output-dir "$UNKNOWN_LINKED_EXTERNAL_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "unknown linked issue visibility fails the external disclosure gate"
assert_true "$([ ! -s "$UNKNOWN_LINKED_CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "unknown linked issue content is never sent to Claude implicitly"
assert_contains "$UNKNOWN_LINKED_OUT" "Linked issue source visibility is UNKNOWN" \
    "the fail-closed linked issue diagnostic identifies unknown visibility"

AUTHORIZED_LINKED_DIR="$TEST_OUTPUT_DIR/authorized-private-linked-external"
AUTHORIZED_LINKED_CLAUDE_LOG="$TEST_OUTPUT_DIR/authorized-linked-claude-invoked.txt"
env PATH="$STUB_DIR:$PATH" REPO_VISIBILITY=PUBLIC \
    LINKED_ISSUE_VISIBILITY=PRIVATE \
    CLAUDE_INVOKED_LOG="$AUTHORIZED_LINKED_CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --allow-external \
    --output-dir "$AUTHORIZED_LINKED_DIR" >/dev/null 2>&1
assert_true "$([ -s "$AUTHORIZED_LINKED_CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "--allow-external authorizes disclosure of a private linked issue"
assert_jq "$AUTHORIZED_LINKED_DIR/analysis-context.json" \
    '.pr.linked_issues[0]
     | .body == "linked repository secret" and
       .repository.visibility == "PRIVATE"' \
    "authorized private linked issue content and visibility reach the analyzer context"

PUBLIC_PRIMARY_DIR="$TEST_OUTPUT_DIR/public-primary-external"
PUBLIC_PRIMARY_CLAUDE_LOG="$TEST_OUTPUT_DIR/public-primary-claude-invoked.txt"
PUBLIC_PRIMARY_QUERY_ARGS_LOG="$TEST_OUTPUT_DIR/public-primary-query-args.txt"
env PATH="$STUB_DIR:$PATH" REPO_VISIBILITY=PUBLIC \
    VISIBILITY_QUERY_ARGS_LOG="$PUBLIC_PRIMARY_QUERY_ARGS_LOG" \
    CLAUDE_INVOKED_LOG="$PUBLIC_PRIMARY_CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --output-dir "$PUBLIC_PRIMARY_DIR" \
    >/dev/null 2>&1
assert_true "$([ -s "$PUBLIC_PRIMARY_CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "a public repository without linked issues reaches external Claude"
assert_contains "$(cat "$PUBLIC_PRIMARY_QUERY_ARGS_LOG")" "nodes(ids: [])" \
    "an empty linked-issue set is encoded as a valid literal GraphQL list"
assert_not_contains "$(cat "$PUBLIC_PRIMARY_QUERY_ARGS_LOG")" "ids[]=" \
    "an empty linked-issue set never emits an absent list variable"

PRIMARY_ID_REUSE_DIR="$TEST_OUTPUT_DIR/primary-repository-id-reuse"
PRIMARY_ID_REUSE_CLAUDE_LOG="$TEST_OUTPUT_DIR/primary-repository-id-reuse-claude.txt"
rc=0
PRIMARY_ID_REUSE_OUT=$(env PATH="$STUB_DIR:$PATH" \
    REPO_VISIBILITY=PUBLIC REPO_ID=REPO_original LIVE_REPO_ID=REPO_replacement \
    CLAUDE_INVOKED_LOG="$PRIMARY_ID_REUSE_CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --output-dir "$PRIMARY_ID_REUSE_DIR" \
    2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a same-name replacement repository cannot reuse the original disclosure grant"
assert_true "$([ ! -s "$PRIMARY_ID_REUSE_CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "primary repository node identity drift is blocked before external egress"
assert_contains "$PRIMARY_ID_REUSE_OUT" \
    "Repository visibility for o/r changed" \
    "the repository identity mismatch fails the final disclosure attestation"

CLAUDE_78_DIR="$TEST_OUTPUT_DIR/claude-exit-78"
CLAUDE_78_LOG="$TEST_OUTPUT_DIR/claude-exit-78-invoked.txt"
rc=0
CLAUDE_78_OUT=$(env PATH="$STUB_DIR:$PATH" REPO_VISIBILITY=PUBLIC \
    CLAUDE_STUB_EXIT_CODE=78 CLAUDE_INVOKED_LOG="$CLAUDE_78_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --output-dir "$CLAUDE_78_DIR" \
    2>&1) || rc=$?
assert_eq "0" "$rc" \
    "Claude exit 78 remains an ordinary soft-degraded analyzer failure" \
    "$CLAUDE_78_OUT"
assert_true "$([ -s "$CLAUDE_78_LOG" ] && echo 0 || echo 1)" \
    "the exit-78 regression reaches Claude after a successful disclosure gate"
assert_contains "$CLAUDE_78_OUT" \
    "Claude analysis failed. Continuing without enrichment." \
    "Claude exit 78 is reported as a provider failure"
assert_not_contains "$CLAUDE_78_OUT" \
    "External disclosure authorization could not be revalidated" \
    "Claude exit 78 cannot masquerade as a disclosure denial"

PUBLIC_LINKED_DIR="$TEST_OUTPUT_DIR/public-linked-external"
PUBLIC_LINKED_CLAUDE_LOG="$TEST_OUTPUT_DIR/public-linked-claude-invoked.txt"
PUBLIC_LINKED_VISIBILITY_LOG="$TEST_OUTPUT_DIR/public-linked-visibility-queries.txt"
PUBLIC_LINKED_QUERY_ARGS_LOG="$TEST_OUTPUT_DIR/public-linked-query-args.txt"
env PATH="$STUB_DIR:$PATH" REPO_VISIBILITY=PUBLIC \
    LINKED_ISSUE_VISIBILITY=PUBLIC \
    VISIBILITY_QUERY_LOG="$PUBLIC_LINKED_VISIBILITY_LOG" \
    VISIBILITY_QUERY_ARGS_LOG="$PUBLIC_LINKED_QUERY_ARGS_LOG" \
    CLAUDE_INVOKED_LOG="$PUBLIC_LINKED_CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --output-dir "$PUBLIC_LINKED_DIR" \
    >/dev/null 2>&1
assert_true "$([ -s "$PUBLIC_LINKED_CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "a public linked issue remains available to external Claude without an override"
assert_jq "$PUBLIC_LINKED_DIR/analysis-context.json" \
    '.pr.linked_issues[0].repository.visibility == "PUBLIC"' \
    "public linked issue visibility is bound into the disclosed context"
assert_eq $'intent/issues\no/r' \
    "$(sort -u "$PUBLIC_LINKED_VISIBILITY_LOG")" \
    "every repository contributing external content is revalidated before disclosure"
assert_contains "$(cat "$PUBLIC_LINKED_QUERY_ARGS_LOG")" \
    "ids[]=ISSUE_linked" \
    "linked issue node IDs are passed with the documented GraphQL list syntax"

PRIMARY_VISIBILITY_DRIFT_DIR="$TEST_OUTPUT_DIR/primary-visibility-drift"
PRIMARY_VISIBILITY_DRIFT_CLAUDE_LOG="$TEST_OUTPUT_DIR/primary-visibility-drift-claude.txt"
rc=0
PRIMARY_VISIBILITY_DRIFT_OUT=$(env PATH="$STUB_DIR:$PATH" \
    REPO_VISIBILITY=PUBLIC LIVE_REPO_VISIBILITY=PRIVATE \
    CLAUDE_INVOKED_LOG="$PRIMARY_VISIBILITY_DRIFT_CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --output-dir "$PRIMARY_VISIBILITY_DRIFT_DIR" \
    2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a public-to-private primary repository change aborts enrichment"
assert_true "$([ ! -s "$PRIMARY_VISIBILITY_DRIFT_CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "primary repository visibility drift is blocked before external egress"
assert_contains "$PRIMARY_VISIBILITY_DRIFT_OUT" \
    "changed from PUBLIC to PRIVATE" \
    "the primary visibility-drift diagnostic identifies both states"

AUTHORIZED_VISIBILITY_DRIFT_DIR="$TEST_OUTPUT_DIR/authorized-visibility-drift"
AUTHORIZED_VISIBILITY_DRIFT_CLAUDE_LOG="$TEST_OUTPUT_DIR/authorized-visibility-drift-claude.txt"
rc=0
AUTHORIZED_VISIBILITY_DRIFT_OUT=$(env PATH="$STUB_DIR:$PATH" \
    REPO_VISIBILITY=PUBLIC LIVE_REPO_VISIBILITY=PRIVATE \
    CLAUDE_INVOKED_LOG="$AUTHORIZED_VISIBILITY_DRIFT_CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --allow-external \
    --output-dir "$AUTHORIZED_VISIBILITY_DRIFT_DIR" 2>&1) || rc=$?
assert_eq "0" "$rc" \
    "explicit disclosure authorization remains valid after a visibility change" \
    "$AUTHORIZED_VISIBILITY_DRIFT_OUT"
assert_true "$([ -s "$AUTHORIZED_VISIBILITY_DRIFT_CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "an explicit override authorizes external egress independently of visibility"

UNKNOWN_OVERRIDE_DIR="$TEST_OUTPUT_DIR/unknown-visibility-override"
UNKNOWN_OVERRIDE_CLAUDE_LOG="$TEST_OUTPUT_DIR/unknown-visibility-override-claude.txt"
rc=0
UNKNOWN_OVERRIDE_OUT=$(env PATH="$STUB_DIR:$PATH" REPO_VISIBILITY=UNKNOWN \
    CLAUDE_INVOKED_LOG="$UNKNOWN_OVERRIDE_CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --allow-external \
    --output-dir "$UNKNOWN_OVERRIDE_DIR" 2>&1) || rc=$?
assert_eq "0" "$rc" \
    "explicit disclosure authorization remains valid when visibility is indeterminate" \
    "$UNKNOWN_OVERRIDE_OUT"
assert_true "$([ -s "$UNKNOWN_OVERRIDE_CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "an explicit override authorizes an indeterminate repository without a cached-public dependency"

LINKED_VISIBILITY_DRIFT_DIR="$TEST_OUTPUT_DIR/linked-visibility-drift"
LINKED_VISIBILITY_DRIFT_CLAUDE_LOG="$TEST_OUTPUT_DIR/linked-visibility-drift-claude.txt"
rc=0
LINKED_VISIBILITY_DRIFT_OUT=$(env PATH="$STUB_DIR:$PATH" \
    REPO_VISIBILITY=PUBLIC LINKED_ISSUE_VISIBILITY=PUBLIC \
    LIVE_LINKED_ISSUE_VISIBILITY=PRIVATE \
    CLAUDE_INVOKED_LOG="$LINKED_VISIBILITY_DRIFT_CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --output-dir "$LINKED_VISIBILITY_DRIFT_DIR" \
    2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a public-to-private linked repository change aborts enrichment"
assert_true "$([ ! -s "$LINKED_VISIBILITY_DRIFT_CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "linked repository visibility drift is blocked before external egress"
assert_contains "$LINKED_VISIBILITY_DRIFT_OUT" \
    "Current linked issue repository visibility or identity could not be verified" \
    "the linked visibility-drift diagnostic identifies the failed attestation"

LINKED_TRANSFER_DIR="$TEST_OUTPUT_DIR/linked-repository-transfer"
LINKED_TRANSFER_CLAUDE_LOG="$TEST_OUTPUT_DIR/linked-repository-transfer-claude.txt"
rc=0
LINKED_TRANSFER_OUT=$(env PATH="$STUB_DIR:$PATH" \
    REPO_VISIBILITY=PUBLIC LINKED_ISSUE_VISIBILITY=PUBLIC \
    LIVE_LINKED_ISSUE_REPOSITORY=intent/private \
    LIVE_LINKED_ISSUE_VISIBILITY=PRIVATE \
    CLAUDE_INVOKED_LOG="$LINKED_TRANSFER_CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --output-dir "$LINKED_TRANSFER_DIR" \
    2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a linked issue transfer to a private repository aborts enrichment"
assert_true "$([ ! -s "$LINKED_TRANSFER_CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "linked issue node identity prevents a transfer from bypassing the disclosure gate"
assert_contains "$LINKED_TRANSFER_OUT" \
    "Current linked issue repository visibility or identity could not be verified" \
    "the linked issue transfer reports a failed live attestation"

UNVERIFIED_VISIBILITY_DIR="$TEST_OUTPUT_DIR/unverified-visibility"
UNVERIFIED_VISIBILITY_CLAUDE_LOG="$TEST_OUTPUT_DIR/unverified-visibility-claude.txt"
rc=0
UNVERIFIED_VISIBILITY_OUT=$(env PATH="$STUB_DIR:$PATH" \
    REPO_VISIBILITY=PUBLIC LIVE_VISIBILITY_QUERY_FAIL_REPO=o/r \
    CLAUDE_INVOKED_LOG="$UNVERIFIED_VISIBILITY_CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --output-dir "$UNVERIFIED_VISIBILITY_DIR" \
    2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "an unverifiable live repository visibility aborts enrichment"
assert_true "$([ ! -s "$UNVERIFIED_VISIBILITY_CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "a visibility lookup failure is blocked before external egress"
assert_contains "$UNVERIFIED_VISIBILITY_OUT" \
    "Current external repository visibility could not be verified" \
    "the visibility lookup failure is reported at the disclosure boundary"

VISIBILITY_SIGNAL_BASH_ENV="$TEST_OUTPUT_DIR/visibility-signal-bash-env"
cat > "$VISIBILITY_SIGNAL_BASH_ENV" << 'STUB'
__gh_pr_enrich_visibility_watchdog_debug() {
    if [ "$BASH_COMMAND" = 'REPORT_RUN_WATCHDOG_PID=$!' ]; then
        printf '%s\n' "$!" >> "$VISIBILITY_SIGNAL_WATCHDOG_PID_FILE"
    fi
}
set -T
trap '__gh_pr_enrich_visibility_watchdog_debug' DEBUG
unset BASH_ENV
STUB

for VISIBILITY_SIGNAL in INT TERM; do
    VISIBILITY_SIGNAL_DIR="$TEST_OUTPUT_DIR/visibility-signal-$VISIBILITY_SIGNAL"
    VISIBILITY_SIGNAL_TMP="$VISIBILITY_SIGNAL_DIR/tmp"
    VISIBILITY_SIGNAL_READY="$VISIBILITY_SIGNAL_DIR/request-ready"
    VISIBILITY_SIGNAL_CHILD_PID_FILE="$VISIBILITY_SIGNAL_DIR/request.pid"
    VISIBILITY_SIGNAL_WATCHDOG_PID_FILE="$VISIBILITY_SIGNAL_DIR/watchdog.pid"
    VISIBILITY_SIGNAL_CLAUDE_LOG="$VISIBILITY_SIGNAL_DIR/claude.txt"
    mkdir -p "$VISIBILITY_SIGNAL_TMP"
    rc=0
    env PATH="$STUB_DIR:$PATH" BASH_ENV="$VISIBILITY_SIGNAL_BASH_ENV" \
        TMPDIR="$VISIBILITY_SIGNAL_TMP" REPO_VISIBILITY=PUBLIC \
        GH_PR_ENRICH_CODE_ACCESS=false GH_PR_ENRICH_GITHUB_TIMEOUT=2 \
        VISIBILITY_SIGNAL="$VISIBILITY_SIGNAL" \
        VISIBILITY_SIGNAL_READY="$VISIBILITY_SIGNAL_READY" \
        VISIBILITY_SIGNAL_CHILD_PID_FILE="$VISIBILITY_SIGNAL_CHILD_PID_FILE" \
        VISIBILITY_SIGNAL_WATCHDOG_PID_FILE="$VISIBILITY_SIGNAL_WATCHDOG_PID_FILE" \
        CLAUDE_INVOKED_LOG="$VISIBILITY_SIGNAL_CLAUDE_LOG" \
        "$GH_PR_ENRICH" 1 --enrich --output-dir "$VISIBILITY_SIGNAL_DIR/report" \
        >/dev/null 2>&1 || rc=$?
    if [ "$VISIBILITY_SIGNAL" = INT ]; then
        VISIBILITY_SIGNAL_EXPECTED_RC=130
    else
        VISIBILITY_SIGNAL_EXPECTED_RC=143
    fi
    assert_true "$([ -e "$VISIBILITY_SIGNAL_READY" ] && echo 0 || echo 1)" \
        "$VISIBILITY_SIGNAL fixture reaches the final visibility request"
    assert_eq "$VISIBILITY_SIGNAL_EXPECTED_RC" "$rc" \
        "$VISIBILITY_SIGNAL during final visibility attestation preserves conventional status"
    assert_true "$([ ! -s "$VISIBILITY_SIGNAL_CLAUDE_LOG" ] && echo 0 || echo 1)" \
        "$VISIBILITY_SIGNAL during visibility attestation prevents external egress"
    VISIBILITY_SIGNAL_CHILD_PID=$(cat "$VISIBILITY_SIGNAL_CHILD_PID_FILE" 2>/dev/null || echo "")
    VISIBILITY_SIGNAL_WATCHDOG_PID=$(tail -1 \
        "$VISIBILITY_SIGNAL_WATCHDOG_PID_FILE" 2>/dev/null || echo "")
    assert_process_reaped "$VISIBILITY_SIGNAL_CHILD_PID" \
        "$VISIBILITY_SIGNAL during visibility attestation reaps the GitHub request"
    assert_process_reaped "$VISIBILITY_SIGNAL_WATCHDOG_PID" \
        "$VISIBILITY_SIGNAL during visibility attestation reaps the request watchdog"
    VISIBILITY_SIGNAL_RESIDUE=$(find "$VISIBILITY_SIGNAL_TMP" \
        -name 'gh-pr-enrich-external-visibility.*' -print -quit)
    assert_true "$([ -z "$VISIBILITY_SIGNAL_RESIDUE" ] && \
        [ ! -e "$VISIBILITY_SIGNAL_DIR/report/.selected-analysis.lock" ] && \
        echo 0 || echo 1)" \
        "$VISIBILITY_SIGNAL cleans visibility staging and releases the report lock"
    VISIBILITY_SIGNAL_CHILD_PID_FILE=""
    VISIBILITY_SIGNAL_WATCHDOG_PID_FILE=""
done

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

# Full-CLI cancellation must restore the caller's EXIT trap so the report-run
# lock is released after the SAST-specific handler publishes terminal state.
SAST_CANCEL_STUBS="$TEST_OUTPUT_DIR/sast-cancel-stubs"
SAST_CANCEL_READY="$TEST_OUTPUT_DIR/sast-cancel-ready"
mkdir -p "$SAST_CANCEL_STUBS"
cat > "$SAST_CANCEL_STUBS/semgrep" << 'STUB'
#!/bin/bash
printf '%s\n' '{"results":[{"check_id":"partial.cancel","path":"gh-pr-enrich","start":{"line":1},"extra":{"severity":"ERROR","message":"partial","metadata":{}}}],"errors":[]}'
printf 'ready\n' > "$SAST_CANCEL_READY"
trap '' TERM INT
if [ -n "${SAST_CANCEL_TARGET_PID:-}" ]; then
    kill -"${SAST_CANCEL_SIGNAL:-INT}" "$SAST_CANCEL_TARGET_PID"
fi
while :; do /bin/sleep 0.05; done
STUB
chmod +x "$SAST_CANCEL_STUBS/semgrep"

SAST_TERM_REPORT="$SAST_WORKSPACE/term-reports"
rm -f "$SAST_CANCEL_READY"
/bin/sh -c '
    cd "$1" || exit 1
    shift
    export SAST_CANCEL_TARGET_PID=$$
    export SAST_CANCEL_SIGNAL=TERM
    exec "$@"
' sh "$SAST_WORKSPACE" env PATH="$SAST_CANCEL_STUBS:$STUB_DIR:$PATH" \
    GH_PR_ENRICH_CODE_ACCESS=true SAST_CANCEL_READY="$SAST_CANCEL_READY" \
    "$GH_PR_ENRICH" 1 --prepare-analysis --sast \
    --output-dir term-reports >/dev/null 2>&1 &
RUNTIME_BACKGROUND_PID=$!
rc=0
wait "$RUNTIME_BACKGROUND_PID" || rc=$?
RUNTIME_BACKGROUND_PID=""
assert_true "$([ -s "$SAST_CANCEL_READY" ] && echo 0 || echo 1)" \
    "the full-CLI TERM fixture reaches SAST while holding the report lock"
assert_eq "143" "$rc" \
    "full-CLI SAST cancellation preserves the conventional TERM status"
assert_true "$([ ! -e "$SAST_TERM_REPORT/.selected-analysis.lock" ] && echo 0 || echo 1)" \
    "full-CLI TERM cancellation releases the report-run lock"
assert_jq "$SAST_TERM_REPORT/sast-status.json" \
    '.status == "failed" and .reason == "semgrep scan cancelled by TERM"' \
    "full-CLI TERM cancellation publishes terminal SAST coverage"

SAST_INT_REPORT="$SAST_WORKSPACE/int-reports"
rm -f "$SAST_CANCEL_READY"
set +e
(cd "$SAST_WORKSPACE" && exec /bin/sh -c '
    export SAST_CANCEL_TARGET_PID=$$
    exec "$@"
' sh env PATH="$SAST_CANCEL_STUBS:$STUB_DIR:$PATH" \
    GH_PR_ENRICH_CODE_ACCESS=true SAST_CANCEL_READY="$SAST_CANCEL_READY" \
    "$GH_PR_ENRICH" 1 --prepare-analysis --sast \
    --output-dir int-reports >/dev/null 2>&1)
rc=$?
set -e
assert_eq "130" "$rc" \
    "full-CLI SAST cancellation preserves the conventional INT status"
assert_true "$([ ! -e "$SAST_INT_REPORT/.selected-analysis.lock" ] && echo 0 || echo 1)" \
    "full-CLI INT cancellation releases the report-run lock"
assert_jq "$SAST_INT_REPORT/sast-status.json" \
    '.status == "failed" and .reason == "semgrep scan cancelled by INT"' \
    "full-CLI INT cancellation publishes terminal SAST coverage"

# Coverage becomes running before workspace fingerprinting. Self-signalling Git
# fixtures make cancellation in that pre-snapshot phase deterministic and prove
# both signal paths publish terminal coverage while releasing the outer lock.
SAST_PRELAUNCH_STUBS="$TEST_OUTPUT_DIR/sast-prelaunch-stubs"
SAST_PRELAUNCH_READY="$TEST_OUTPUT_DIR/sast-prelaunch-ready"
mkdir -p "$SAST_PRELAUNCH_STUBS"
cat > "$SAST_PRELAUNCH_STUBS/git" << 'STUB'
#!/bin/bash
case "$*" in
    *"ls-files --stage"*)
        if [ -n "${SAST_PRELAUNCH_SIGNAL:-}" ]; then
            printf 'ready\n' > "$SAST_PRELAUNCH_READY"
            kill -"$SAST_PRELAUNCH_SIGNAL" "$SAST_PRELAUNCH_TARGET_PID"
            case "$SAST_PRELAUNCH_SIGNAL" in
                TERM) exit 143 ;;
                INT) exit 130 ;;
            esac
        fi
        ;;
esac
exec "$SAST_PRELAUNCH_REAL_GIT" "$@"
STUB
chmod +x "$SAST_PRELAUNCH_STUBS/git"
for SAST_PRELAUNCH_SIGNAL in TERM INT; do
    case "$SAST_PRELAUNCH_SIGNAL" in
        TERM) SAST_PRELAUNCH_EXPECTED_RC=143 ;;
        INT) SAST_PRELAUNCH_EXPECTED_RC=130 ;;
    esac
    SAST_PRELAUNCH_REPORT="$SAST_WORKSPACE/prelaunch-$SAST_PRELAUNCH_SIGNAL-reports"
    rm -f "$SAST_PRELAUNCH_READY"
    set +e
    (cd "$SAST_WORKSPACE" && exec /bin/sh -c '
        export SAST_PRELAUNCH_TARGET_PID=$$
        exec "$@"
    ' sh env PATH="$SAST_PRELAUNCH_STUBS:$STUB_DIR:$PATH" \
        SAST_PRELAUNCH_SIGNAL="$SAST_PRELAUNCH_SIGNAL" \
        SAST_PRELAUNCH_READY="$SAST_PRELAUNCH_READY" \
        SAST_PRELAUNCH_REAL_GIT="$(command -v git)" \
        GH_PR_ENRICH_CODE_ACCESS=true \
        "$GH_PR_ENRICH" 1 --prepare-analysis --sast \
        --output-dir "prelaunch-$SAST_PRELAUNCH_SIGNAL-reports" \
        >/dev/null 2>&1)
    rc=$?
    set -e
    assert_true "$([ -s "$SAST_PRELAUNCH_READY" ] && echo 0 || echo 1)" \
        "$SAST_PRELAUNCH_SIGNAL fixture cancels during pre-snapshot fingerprinting"
    assert_eq "$SAST_PRELAUNCH_EXPECTED_RC" "$rc" \
        "pre-snapshot $SAST_PRELAUNCH_SIGNAL preserves the conventional status"
    assert_true "$([ ! -e "$SAST_PRELAUNCH_REPORT/.selected-analysis.lock" ] && echo 0 || echo 1)" \
        "pre-snapshot $SAST_PRELAUNCH_SIGNAL releases the report-run lock"
    assert_jq "$SAST_PRELAUNCH_REPORT/sast-status.json" \
        ".status == \"failed\" and .reason == \"semgrep scan cancelled by $SAST_PRELAUNCH_SIGNAL\"" \
        "pre-snapshot $SAST_PRELAUNCH_SIGNAL publishes terminal SAST coverage"
done

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
rc=0
AUTHORIZED_OUT=$(env PATH="$STUB_DIR:$PATH" REPO_VISIBILITY=PRIVATE \
    GH_PR_ENRICH_CODE_ACCESS=false \
    CLAUDE_INVOKED_LOG="$CLAUDE_LOG" \
    "$GH_PR_ENRICH" 1 --enrich --allow-external --diff \
    --output-dir "$AUTHORIZED_DIR" 2>&1) || rc=$?
assert_eq "0" "$rc" \
    "authorized private enrichment completes provider publication" \
    "$AUTHORIZED_OUT"

assert_true "$([ -s "$CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "--allow-external authorizes Claude for a private repository"
assert_jq "$AUTHORIZED_DIR/analysis.json" '._metadata.repository_visibility == "PRIVATE"' \
    "the analysis provenance records repository visibility"
AUTHORIZED_CLAUDE_FIXTURE="$TEST_OUTPUT_DIR/authorized-claude-fixture.json"
cp "$AUTHORIZED_DIR/claude-analysis.json" "$AUTHORIZED_CLAUDE_FIXTURE"

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
        if [ ! -f "$PROVIDER_COLLISION_MARKER" ]; then
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

# Claude source files remain private until the same transaction that updates
# combined-data. A comment added after private provider staging must fail the
# final hosted-state check and publish none of those provider views.
PROVIDER_DISCUSSION_DIR="$TEST_OUTPUT_DIR/provider-discussion-drift"
PROVIDER_DISCUSSION_STUBS="$TEST_OUTPUT_DIR/provider-discussion-stubs"
PROVIDER_DISCUSSION_MARKER="$TEST_OUTPUT_DIR/provider-discussion-fired"
mkdir -p "$PROVIDER_DISCUSSION_STUBS"
cat > "$PROVIDER_DISCUSSION_STUBS/cp" << 'STUB'
#!/bin/bash
destination=""
for argument in "$@"; do destination="$argument"; done
case "$destination" in
    "$PROVIDER_DISCUSSION_REPORT"/.selected-analysis-replacements.*/claude-analysis.json)
        : > "$PROVIDER_DISCUSSION_MARKER"
        ;;
esac
exec "$PROVIDER_DISCUSSION_REAL_CP" "$@"
STUB
cat > "$PROVIDER_DISCUSSION_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1" = "api" ] && [ "$2" != "graphql" ] && \
   [ -e "$PROVIDER_DISCUSSION_MARKER" ]; then
    case "$*" in
        *repos/o/r/issues/1/comments*)
            echo '[{"id":99,"body":"late provider comment","user":{"login":"reviewer"},"created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","html_url":"https://github.com/o/r/pull/1#issuecomment-99"}]'
            exit 0
            ;;
    esac
fi
exec "$PROVIDER_DISCUSSION_BASE_GH" "$@"
STUB
cat > "$PROVIDER_DISCUSSION_STUBS/claude" << 'STUB'
#!/bin/bash
"$PROVIDER_DISCUSSION_BASE_CLAUDE" "$@"
claude_rc=$?
if [ "$claude_rc" -eq 0 ]; then
    cp "$PROVIDER_DISCUSSION_STALE_ANALYSIS" \
        "$PROVIDER_DISCUSSION_REPORT/analysis.json"
    cp "$PROVIDER_DISCUSSION_STALE_ANALYSIS" \
        "$PROVIDER_DISCUSSION_REPORT/claude-analysis.json"
    printf '%s\n' '# stale selected report' \
        > "$PROVIDER_DISCUSSION_REPORT/analysis.md"
    printf '%s\n' '# stale context coverage' \
        > "$PROVIDER_DISCUSSION_REPORT/context-coverage.md"
    printf '%s\n' '# stale provider report' \
        > "$PROVIDER_DISCUSSION_REPORT/claude-analysis.md"
    combined_tmp="$(mktemp \
        "$PROVIDER_DISCUSSION_REPORT/.provider-stale-combined.XXXXXX")" || exit 1
    jq --slurpfile stale "$PROVIDER_DISCUSSION_STALE_ANALYSIS" \
        '.analysis=$stale[0] | .claude_analysis=$stale[0]
         | .analysis_context_coverage={stale:true}' \
        "$PROVIDER_DISCUSSION_REPORT/combined-data.json" > "$combined_tmp" || exit 1
    mv "$combined_tmp" "$PROVIDER_DISCUSSION_REPORT/combined-data.json"
    cat >> "$PROVIDER_DISCUSSION_REPORT/comprehensive-report.md" << 'EOF'

<!-- BEGIN SELECTED ANALYSIS -->

stale selected result

<!-- END SELECTED ANALYSIS -->
EOF
fi
exit "$claude_rc"
STUB
chmod +x "$PROVIDER_DISCUSSION_STUBS/cp" \
    "$PROVIDER_DISCUSSION_STUBS/gh" \
    "$PROVIDER_DISCUSSION_STUBS/claude"
rc=0
PROVIDER_DISCUSSION_OUT=$(env PATH="$PROVIDER_DISCUSSION_STUBS:$STUB_DIR:$PATH" \
    REPO_VISIBILITY=PRIVATE GH_PR_ENRICH_CODE_ACCESS=false \
    CLAUDE_INVOKED_LOG="$CLAUDE_LOG" \
    PROVIDER_DISCUSSION_REPORT="$PROVIDER_DISCUSSION_DIR" \
    PROVIDER_DISCUSSION_MARKER="$PROVIDER_DISCUSSION_MARKER" \
    PROVIDER_DISCUSSION_REAL_CP="$(command -v cp)" \
    PROVIDER_DISCUSSION_BASE_GH="$STUB_DIR/gh" \
    PROVIDER_DISCUSSION_BASE_CLAUDE="$STUB_DIR/claude" \
    PROVIDER_DISCUSSION_STALE_ANALYSIS="$AUTHORIZED_CLAUDE_FIXTURE" \
    "$GH_PR_ENRICH" 1 --enrich --allow-external \
    --output-dir "$PROVIDER_DISCUSSION_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ -e "$PROVIDER_DISCUSSION_MARKER" ] && \
    echo 0 || echo 1)" \
    "provider publication detects discussion drift after private staging" \
    "$PROVIDER_DISCUSSION_OUT"
assert_contains "$PROVIDER_DISCUSSION_OUT" \
    "Hosted PR head, checks, discussion, and intent could not be attested before provider publication" \
    "provider rejection names the final hosted discussion boundary"
assert_true "$([ ! -e "$PROVIDER_DISCUSSION_DIR/claude-analysis.json" ] && \
    [ ! -e "$PROVIDER_DISCUSSION_DIR/claude-analysis.md" ] && \
    [ ! -e "$PROVIDER_DISCUSSION_DIR/analysis.json" ] && \
    [ ! -e "$PROVIDER_DISCUSSION_DIR/analysis.md" ] && \
    [ ! -e "$PROVIDER_DISCUSSION_DIR/context-coverage.md" ] && echo 0 || echo 1)" \
    "late provider discussion drift invalidates prior provider and selected views"
assert_jq "$PROVIDER_DISCUSSION_DIR/combined-data.json" \
    '(has("analysis") | not) and
     (has("analysis_context_coverage") | not) and
     (has("claude_analysis") | not)' \
    "late provider discussion drift strips every stale embedded analysis"
assert_true "$(! grep -Fq '<!-- BEGIN SELECTED ANALYSIS -->' \
    "$PROVIDER_DISCUSSION_DIR/comprehensive-report.md" && echo 0 || echo 1)" \
    "late provider discussion drift removes stale selected report sections"
assert_no_selection_transaction_residue "$PROVIDER_DISCUSSION_DIR" \
    "late provider discussion drift cleans every publication transaction"

# The atomic hosted attestation brackets the stable discussion snapshot with
# head reads. Advance only the second attestation head read so deleting that
# final comparison would make this regression publish stale provider data.
PROVIDER_HEAD_DIR="$TEST_OUTPUT_DIR/provider-attestation-head-drift"
PROVIDER_HEAD_STUBS="$TEST_OUTPUT_DIR/provider-attestation-head-stubs"
PROVIDER_HEAD_MARKER="$TEST_OUTPUT_DIR/provider-attestation-head-staged"
PROVIDER_HEAD_COUNT="$TEST_OUTPUT_DIR/provider-attestation-head-count"
mkdir -p "$PROVIDER_HEAD_STUBS"
cat > "$PROVIDER_HEAD_STUBS/cp" << 'STUB'
#!/bin/bash
destination=""
for argument in "$@"; do destination="$argument"; done
case "$destination" in
    "$PROVIDER_HEAD_REPORT"/.selected-analysis-replacements.*/claude-analysis.json)
        : > "$PROVIDER_HEAD_MARKER"
        ;;
esac
exec "$PROVIDER_HEAD_REAL_CP" "$@"
STUB
cat > "$PROVIDER_HEAD_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr view" ] && [ -e "$PROVIDER_HEAD_MARKER" ]; then
    count=$(cat "$PROVIDER_HEAD_COUNT" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$PROVIDER_HEAD_COUNT"
    if [ "$count" -ge 2 ]; then
        if [ "${PROVIDER_DRIFT_BASE_ONLY:-false}" = true ]; then
            PR_BASE_OID=new-hosted-base exec "$PROVIDER_HEAD_BASE_GH" "$@"
        fi
        PR_HEAD_OID=new-hosted-head exec "$PROVIDER_HEAD_BASE_GH" "$@"
    fi
fi
exec "$PROVIDER_HEAD_BASE_GH" "$@"
STUB
chmod +x "$PROVIDER_HEAD_STUBS/cp" "$PROVIDER_HEAD_STUBS/gh"
rc=0
PROVIDER_HEAD_OUT=$(env PATH="$PROVIDER_HEAD_STUBS:$STUB_DIR:$PATH" \
    REPO_VISIBILITY=PRIVATE GH_PR_ENRICH_CODE_ACCESS=false \
    CLAUDE_INVOKED_LOG="$CLAUDE_LOG" \
    PROVIDER_HEAD_REPORT="$PROVIDER_HEAD_DIR" \
    PROVIDER_HEAD_MARKER="$PROVIDER_HEAD_MARKER" \
    PROVIDER_HEAD_COUNT="$PROVIDER_HEAD_COUNT" \
    PROVIDER_HEAD_REAL_CP="$(command -v cp)" \
    PROVIDER_HEAD_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" 1 --enrich --allow-external \
    --output-dir "$PROVIDER_HEAD_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ "$(cat "$PROVIDER_HEAD_COUNT" \
    2>/dev/null || echo 0)" -eq 2 ] && echo 0 || echo 1)" \
    "provider attestation rejects a head advance on its second head read" \
    "$PROVIDER_HEAD_OUT"
assert_true "$([ ! -e "$PROVIDER_HEAD_DIR/claude-analysis.json" ] && \
    [ ! -e "$PROVIDER_HEAD_DIR/claude-analysis.md" ] && \
    [ ! -e "$PROVIDER_HEAD_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "second-head attestation drift publishes no provider or selected analysis"
assert_no_selection_transaction_residue "$PROVIDER_HEAD_DIR" \
    "second-head attestation drift cleans every publication transaction"

PROVIDER_BASE_DIR="$TEST_OUTPUT_DIR/provider-attestation-base-drift"
PROVIDER_BASE_MARKER="$TEST_OUTPUT_DIR/provider-attestation-base-staged"
PROVIDER_BASE_COUNT="$TEST_OUTPUT_DIR/provider-attestation-base-count"
rc=0
PROVIDER_BASE_OUT=$(env PATH="$PROVIDER_HEAD_STUBS:$STUB_DIR:$PATH" \
    REPO_VISIBILITY=PRIVATE GH_PR_ENRICH_CODE_ACCESS=false \
    CLAUDE_INVOKED_LOG="$CLAUDE_LOG" PROVIDER_DRIFT_BASE_ONLY=true \
    PROVIDER_HEAD_REPORT="$PROVIDER_BASE_DIR" \
    PROVIDER_HEAD_MARKER="$PROVIDER_BASE_MARKER" \
    PROVIDER_HEAD_COUNT="$PROVIDER_BASE_COUNT" \
    PROVIDER_HEAD_REAL_CP="$(command -v cp)" \
    PROVIDER_HEAD_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" 1 --enrich --allow-external \
    --output-dir "$PROVIDER_BASE_DIR" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ "$(cat "$PROVIDER_BASE_COUNT" \
    2>/dev/null || echo 0)" -eq 2 ] && echo 0 || echo 1)" \
    "provider attestation rejects a same-head base advance on its second revision read" \
    "$PROVIDER_BASE_OUT"
assert_true "$([ ! -e "$PROVIDER_BASE_DIR/claude-analysis.json" ] && \
    [ ! -e "$PROVIDER_BASE_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "second-revision base drift publishes no provider or selected analysis"

# TERM sent to the top-level CLI while the provider's hosted attestation is
# blocked must reach the managed provider transaction and its active API
# descendant before any provider or selected view is published.
PROVIDER_SIGNAL_DIR="$TEST_OUTPUT_DIR/provider-signal"
PROVIDER_SIGNAL_STUBS="$TEST_OUTPUT_DIR/provider-signal-stubs"
PROVIDER_SIGNAL_MARKER="$TEST_OUTPUT_DIR/provider-signal-staged"
PROVIDER_SIGNAL_READY="$TEST_OUTPUT_DIR/provider-signal-ready"
PROVIDER_SIGNAL_CHILD_PID_FILE="$TEST_OUTPUT_DIR/provider-signal-child-pid"
PROVIDER_SIGNAL_DESCENDANT_PID_FILE="$TEST_OUTPUT_DIR/provider-signal-descendant-pid"
PROVIDER_SIGNAL_LIVE_DIR_FILE="$TEST_OUTPUT_DIR/provider-signal-live-dir"
PROVIDER_SIGNAL_LIVE_BASELINE_FILE="$TEST_OUTPUT_DIR/provider-signal-live-baseline"
PROVIDER_SIGNAL_SOURCE_DIR_FILE="$TEST_OUTPUT_DIR/provider-signal-source-dir"
PROVIDER_SIGNAL_BACKUP_DIR_FILE="$TEST_OUTPUT_DIR/provider-signal-backup-dir"
PROVIDER_SIGNAL_OUT="$TEST_OUTPUT_DIR/provider-signal.out"
mkdir -p "$PROVIDER_SIGNAL_STUBS"
cat > "$PROVIDER_SIGNAL_STUBS/cp" << 'STUB'
#!/bin/bash
destination=""
source_path=""
for argument in "$@"; do destination="$argument"; done
for argument in "$@"; do
    case "$argument" in -*) continue ;; esac
    source_path="$argument"
    break
done
case "$destination" in
    "$PROVIDER_SIGNAL_REPORT"/.selected-analysis-replacements.*/claude-analysis.json)
        dirname "$source_path" > "$PROVIDER_SIGNAL_SOURCE_DIR_FILE"
        : > "$PROVIDER_SIGNAL_MARKER"
        ;;
    "$PROVIDER_SIGNAL_REPORT"/.selected-analysis-replacements.*/combined-data.json)
        case "$source_path" in
            /tmp/gh-pr-enrich-provider-update.*/combined-data.json)
                dirname "$source_path" > "$PROVIDER_SIGNAL_BACKUP_DIR_FILE"
                ;;
        esac
        ;;
esac
exec "$PROVIDER_SIGNAL_REAL_CP" "$@"
STUB
cat > "$PROVIDER_SIGNAL_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1" = "api" ] && [ "$2" != "graphql" ] && \
   [ -e "$PROVIDER_SIGNAL_MARKER" ]; then
    case "$*" in
        *repos/o/r/issues/1/comments*)
            printf '%s\n' "$$" > "$PROVIDER_SIGNAL_CHILD_PID_FILE"
            (
                trap '' TERM INT
                while :; do sleep 1; done
            ) &
            descendant_pid=$!
            printf '%s\n' "$descendant_pid" \
                > "$PROVIDER_SIGNAL_DESCENDANT_PID_FILE"
            : > "$PROVIDER_SIGNAL_LIVE_DIR_FILE"
            for live_dir in /tmp/gh-pr-enrich-live-discussion.*; do
                [ -d "$live_dir" ] || continue
                if ! grep -Fxq "$live_dir" \
                        "$PROVIDER_SIGNAL_LIVE_BASELINE_FILE" 2>/dev/null; then
                    printf '%s\n' "$live_dir" \
                        > "$PROVIDER_SIGNAL_LIVE_DIR_FILE"
                    break
                fi
            done
            : > "$PROVIDER_SIGNAL_READY"
            trap 'exit 143' TERM
            trap 'exit 130' INT
            wait "$descendant_pid"
            exit $?
            ;;
    esac
fi
exec "$PROVIDER_SIGNAL_BASE_GH" "$@"
STUB
chmod +x "$PROVIDER_SIGNAL_STUBS/cp" "$PROVIDER_SIGNAL_STUBS/gh"
find /tmp -maxdepth 1 -type d \
    -name 'gh-pr-enrich-live-discussion.*' -print \
    > "$PROVIDER_SIGNAL_LIVE_BASELINE_FILE"
RUNTIME_BACKGROUND_PID=""
env PATH="$PROVIDER_SIGNAL_STUBS:$STUB_DIR:$PATH" \
    REPO_VISIBILITY=PRIVATE GH_PR_ENRICH_CODE_ACCESS=false \
    CLAUDE_INVOKED_LOG="$CLAUDE_LOG" \
    PROVIDER_SIGNAL_REPORT="$PROVIDER_SIGNAL_DIR" \
    PROVIDER_SIGNAL_MARKER="$PROVIDER_SIGNAL_MARKER" \
    PROVIDER_SIGNAL_READY="$PROVIDER_SIGNAL_READY" \
    PROVIDER_SIGNAL_CHILD_PID_FILE="$PROVIDER_SIGNAL_CHILD_PID_FILE" \
    PROVIDER_SIGNAL_DESCENDANT_PID_FILE="$PROVIDER_SIGNAL_DESCENDANT_PID_FILE" \
    PROVIDER_SIGNAL_LIVE_DIR_FILE="$PROVIDER_SIGNAL_LIVE_DIR_FILE" \
    PROVIDER_SIGNAL_LIVE_BASELINE_FILE="$PROVIDER_SIGNAL_LIVE_BASELINE_FILE" \
    PROVIDER_SIGNAL_SOURCE_DIR_FILE="$PROVIDER_SIGNAL_SOURCE_DIR_FILE" \
    PROVIDER_SIGNAL_BACKUP_DIR_FILE="$PROVIDER_SIGNAL_BACKUP_DIR_FILE" \
    PROVIDER_SIGNAL_REAL_CP="$(command -v cp)" \
    PROVIDER_SIGNAL_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" 1 --enrich --allow-external \
    --output-dir "$PROVIDER_SIGNAL_DIR" \
    > "$PROVIDER_SIGNAL_OUT" 2>&1 &
RUNTIME_BACKGROUND_PID=$!
for (( _provider_wait=0; _provider_wait < 600; _provider_wait++ )); do
    [ -e "$PROVIDER_SIGNAL_READY" ] && break
    kill -0 "$RUNTIME_BACKGROUND_PID" 2>/dev/null || break
    sleep 0.05
done
assert_true "$([ -e "$PROVIDER_SIGNAL_READY" ] && echo 0 || echo 1)" \
    "provider TERM fixture blocks inside final hosted attestation" \
    "$(cat "$PROVIDER_SIGNAL_OUT" 2>/dev/null || true)"
PROVIDER_SIGNAL_LIVE_DIR=$(cat "$PROVIDER_SIGNAL_LIVE_DIR_FILE" \
    2>/dev/null || echo "")
assert_true "$([ -n "$PROVIDER_SIGNAL_LIVE_DIR" ] && \
    [ -d "$PROVIDER_SIGNAL_LIVE_DIR" ] && echo 0 || echo 1)" \
    "provider TERM fixture captures its live-discussion staging directory"
PROVIDER_SIGNAL_SOURCE_DIR=$(cat "$PROVIDER_SIGNAL_SOURCE_DIR_FILE" \
    2>/dev/null || echo "")
PROVIDER_SIGNAL_BACKUP_DIR=$(cat "$PROVIDER_SIGNAL_BACKUP_DIR_FILE" \
    2>/dev/null || echo "")
assert_true "$([ -n "$PROVIDER_SIGNAL_SOURCE_DIR" ] && \
    [ -d "$PROVIDER_SIGNAL_SOURCE_DIR" ] && \
    [ -n "$PROVIDER_SIGNAL_BACKUP_DIR" ] && \
    [ -d "$PROVIDER_SIGNAL_BACKUP_DIR" ] && echo 0 || echo 1)" \
    "provider TERM fixture captures its exact source and backup staging directories"
PROVIDER_SIGNAL_TOP_PID="$RUNTIME_BACKGROUND_PID"
kill -TERM "$PROVIDER_SIGNAL_TOP_PID" 2>/dev/null || true
rc=0
wait "$PROVIDER_SIGNAL_TOP_PID" || rc=$?
RUNTIME_BACKGROUND_PID=""
assert_eq "143" "$rc" \
    "top-level TERM during provider attestation preserves the conventional status"
PROVIDER_SIGNAL_CHILD_PID=$(cat "$PROVIDER_SIGNAL_CHILD_PID_FILE" 2>/dev/null || echo "")
PROVIDER_SIGNAL_DESCENDANT_PID=$(cat \
    "$PROVIDER_SIGNAL_DESCENDANT_PID_FILE" 2>/dev/null || echo "")
assert_process_reaped "$PROVIDER_SIGNAL_CHILD_PID" \
    "provider TERM reaps the active hosted-attestation child"
assert_process_reaped "$PROVIDER_SIGNAL_DESCENDANT_PID" \
    "provider TERM escalates and reaps a TERM-ignoring attestation descendant"
assert_true "$([ ! -e "$PROVIDER_SIGNAL_DIR/claude-analysis.json" ] && \
    [ ! -e "$PROVIDER_SIGNAL_DIR/claude-analysis.md" ] && \
    [ ! -e "$PROVIDER_SIGNAL_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "provider TERM publishes no provider or selected analysis"
assert_true "$([ ! -e "$PROVIDER_SIGNAL_LIVE_DIR" ] && echo 0 || echo 1)" \
    "provider TERM removes the live-discussion staging directory"
assert_true "$([ ! -e "$PROVIDER_SIGNAL_SOURCE_DIR" ] && \
    [ ! -e "$PROVIDER_SIGNAL_BACKUP_DIR" ] && echo 0 || echo 1)" \
    "provider TERM removes source and backup staging directories" \
    "source: $PROVIDER_SIGNAL_SOURCE_DIR; backup: $PROVIDER_SIGNAL_BACKUP_DIR"
assert_no_selection_transaction_residue "$PROVIDER_SIGNAL_DIR" \
    "provider TERM cleans every lock and publication transaction"

# Standalone immutable selection inputs are created directly in the system
# temporary directory. Their source artifacts may be world-readable, but the
# frozen copies must remain private from the instant cp writes them.
PRIVATE_FREEZE_DIR="$TEST_OUTPUT_DIR/private-selection-freeze"
PRIVATE_FREEZE_STUBS="$TEST_OUTPUT_DIR/private-selection-freeze-stubs"
PRIVATE_FREEZE_MODE_LOG="$TEST_OUTPUT_DIR/private-selection-freeze-modes.txt"
mkdir -p "$PRIVATE_FREEZE_DIR" "$PRIVATE_FREEZE_STUBS"
cp -R "$AUTHORIZED_DIR/." "$PRIVATE_FREEZE_DIR/"
PRIVATE_FREEZE_SOURCE="$PRIVATE_FREEZE_DIR/private-freeze-source.json"
cp "$AUTHORIZED_DIR/analysis.json" "$PRIVATE_FREEZE_SOURCE"
chmod 644 "$PRIVATE_FREEZE_SOURCE" \
    "$PRIVATE_FREEZE_DIR/analysis-context.json"
cat > "$PRIVATE_FREEZE_STUBS/cp" << 'STUB'
#!/bin/bash
destination=""
for argument in "$@"; do destination="$argument"; done
"$REAL_CP" "$@" || exit $?
case "$destination" in
    /tmp/gh-pr-enrich-analysis-source.*|\
    /private/tmp/gh-pr-enrich-analysis-source.*|\
    /tmp/gh-pr-enrich-analysis-context.*|\
    /private/tmp/gh-pr-enrich-analysis-context.*)
        mode=$(stat -c '%a' "$destination" 2>/dev/null || \
            stat -f '%Lp' "$destination") || exit 1
        printf '%s\t%s\n' "$destination" "$mode" \
            >> "$PRIVATE_FREEZE_MODE_LOG"
        ;;
esac
STUB
chmod +x "$PRIVATE_FREEZE_STUBS/cp"
rc=0
env PATH="$PRIVATE_FREEZE_STUBS:$STUB_DIR:$PATH" \
    REAL_CP="$(command -v cp)" \
    PRIVATE_FREEZE_MODE_LOG="$PRIVATE_FREEZE_MODE_LOG" \
    "$GH_PR_ENRICH" select-analysis "$PRIVATE_FREEZE_DIR" \
    "$PRIVATE_FREEZE_SOURCE" >/dev/null 2>&1 || rc=$?
assert_eq "0" "$rc" \
    "selection succeeds while freezing normally readable source artifacts"
assert_true "$([ "$(wc -l < "$PRIVATE_FREEZE_MODE_LOG" | tr -d ' ')" = 2 ] && \
    [ "$(awk -F '\t' '$2 == 600 { count++ } END { print count + 0 }' \
        "$PRIVATE_FREEZE_MODE_LOG")" = 2 ] && echo 0 || echo 1)" \
    "selection copies both standalone immutable inputs with private permissions"
assert_true "$([ "$("$GH_PR_ENRICH" --test-call workspace_file_mode \
        "$PRIVATE_FREEZE_SOURCE")" = 644 ] && \
    [ "$("$GH_PR_ENRICH" --test-call workspace_file_mode \
        "$PRIVATE_FREEZE_DIR/analysis-context.json")" = 644 ] && \
    echo 0 || echo 1)" \
    "selection does not change the live source artifact permissions"
PRIVATE_FREEZE_RESIDUE=false
while IFS=$'\t' read -r frozen_path _mode; do
    [ ! -e "$frozen_path" ] || PRIVATE_FREEZE_RESIDUE=true
done < "$PRIVATE_FREEZE_MODE_LOG"
assert_eq "false" "$PRIVATE_FREEZE_RESIDUE" \
    "selection removes both private standalone immutable inputs"

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
assert_contains "$SELECT_ABA_OUT" \
    "source or context changed while its immutable copy" \
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
CAPTURED_BASE=$(jq -r '.pr.base_sha' "$AUTHORIZED_DIR/analysis-context.json")
CAPTURED_BASE_REF=$(jq -r '.pr.base_ref_name' "$AUTHORIZED_DIR/analysis-context.json")
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
    PRIVATE "$CAPTURED_HEAD" "$CAPTURED_BASE" "$CAPTURED_BASE_REF" \
    "$CAPTURED_FINGERPRINT"
assert_jq "$PROVENANCE_DIR/claude-analysis.json" \
    "._metadata.pr_head_sha == \"$CAPTURED_HEAD\" and
     ._metadata.pr_base_sha == \"$CAPTURED_BASE\" and
     ._metadata.pr_base_ref_name == \"$CAPTURED_BASE_REF\" and
     ._metadata.context_fingerprint == \"$CAPTURED_FINGERPRINT\"" \
    "artifact provenance uses captured values instead of rereading refreshed context"
rc=0
PROVENANCE_RACE_OUT=$(PATH="$STUB_DIR:$PATH" "$GH_PR_ENRICH" select-analysis \
    "$PROVENANCE_DIR" "$PROVENANCE_DIR/claude-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects captured artifact metadata against a later context refresh"
assert_contains "$PROVENANCE_RACE_OUT" "context fingerprint" \
    "the post-verification context race fails at immutable identity validation"

HYBRID_SOURCE="$AUTHORIZED_DIR/hybrid-analysis.json"
jq '.task_list = []
    | .process_improvements = [{
        category: "testing", suggestion: "Hybrid-selected improvement",
        rationale: "fixture"
    }]
    | ._metadata.provider = "hybrid"
    | ._metadata.analyzers = [
        {provider: "codex", role: "orchestrator"},
        {provider: "claude", role: "external"}
    ]' "$AUTHORIZED_DIR/analysis.json" > "$HYBRID_SOURCE"

# Selection performs its own hosted-state check, so all selector calls use the
# deterministic GitHub stub rather than the developer's live checkout.
export PATH="$STUB_DIR:$PATH"

validate_candidate_contract() {
    local report_dir="$1" source_file="$2"
    local context_file="$report_dir/analysis-context.json"
    local context_fingerprint
    context_fingerprint=$(
        "$GH_PR_ENRICH" --test-call analysis_context_fingerprint "$context_file"
    ) || return 1
    "$GH_PR_ENRICH" --test-call validate_analysis_candidate \
        "$report_dir" "$source_file" "$context_file" "$context_fingerprint"
}

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
assert_contains "$(cat "$AUTHORIZED_DIR/analysis.md")" "No tasks generated" \
    "select-analysis regenerates the selected Markdown report"
assert_jq "$AUTHORIZED_DIR/combined-data.json" \
    '.analysis._metadata.provider == "hybrid" and (.analysis.task_list | length) == 0' \
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
      finding_id:("matrix-" + (.key | tostring)),
      name:("Matrix tuple " + (.key | tostring)), category:"logic_error",
      severity_rationale:"matrix fixture", verdict:"plausible", confidence:"medium",
      description:"matrix fixture", evidence:[{file:"a.js",line:1,detail:"fixture"}],
      thread_ids:[], sources:["codex:orchestrator"]
    }))
    | .category_coverage |= map(if .category == "logic_error"
        then .verdict = "findings_reported" else . end)
' "$HYBRID_SOURCE" > "$VALID_SEVERITY_SOURCE"
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$VALID_SEVERITY_SOURCE" >/dev/null
assert_jq "$VALID_SEVERITY_SOURCE" \
    '.issue_categories | length == 12' \
    "selection accepts every documented severity-matrix tuple"
jq '.issue_categories[0].severity = "low"' \
    "$VALID_SEVERITY_SOURCE" > "$INVALID_SEVERITY_SOURCE"
rc=0
INVALID_SEVERITY_OUT=$(validate_candidate_contract "$AUTHORIZED_DIR" \
    "$INVALID_SEVERITY_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects a severity that contradicts impact and likelihood"
assert_contains "$INVALID_SEVERITY_OUT" "missing required findings or provenance" \
    "the invalid severity tuple fails selected-analysis contract validation"

FROZEN_SOURCE="$AUTHORIZED_DIR/freeze-race-analysis.json"
jq '.process_improvements[0].suggestion = "frozen before hosted verification"' \
    "$HYBRID_SOURCE" > "$FROZEN_SOURCE"
TMPDIR="$AUTHORIZED_DIR" MUTATE_ANALYSIS_SOURCE="$FROZEN_SOURCE" \
    "$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$FROZEN_SOURCE" >/dev/null
assert_jq "$AUTHORIZED_DIR/analysis.json" \
    '.process_improvements[0].suggestion == "frozen before hosted verification"' \
    "selection publishes the private frozen source when the original changes mid-validation"
assert_jq "$FROZEN_SOURCE" '.process_improvements[0].suggestion == "mutated after selector freeze"' \
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
jq '.process_improvements[0].suggestion = "must not publish refreshed-context race"' \
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
    '.process_improvements[0].suggestion == "frozen before hosted verification"' \
    "a context refresh race preserves the previously selected analysis"
cp "$CONTEXT_RACE_ORIGINAL" "$AUTHORIZED_DIR/analysis-context.json"

# Disputes are informational, so their reference may be either a captured
# PRRT ID or the exact URL of a non-thread comment. Mutation-bearing finding
# and task thread IDs remain PRRT-only.
DISPUTE_CONTEXT_ORIGINAL="$TEST_OUTPUT_DIR/dispute-context-original.json"
DISPUTE_CONTEXT_TMP="$TEST_OUTPUT_DIR/dispute-context.tmp.json"
DISPUTE_SOURCE="$AUTHORIZED_DIR/disputed-comments-analysis.json"
UNKNOWN_DISPUTE_SOURCE="$AUTHORIZED_DIR/unknown-dispute-analysis.json"
FINDING_URL_SOURCE="$AUTHORIZED_DIR/finding-url-analysis.json"
TASK_URL_SOURCE="$AUTHORIZED_DIR/task-url-analysis.json"
cp "$AUTHORIZED_DIR/analysis-context.json" "$DISPUTE_CONTEXT_ORIGINAL"
jq 'del(.coverage.context_fingerprint)
    | .issue_comments += [{user:"u",body:"issue claim",
        url:"https://github.com/o/r/pull/1#issuecomment-10",created_at:"t"}]
    | .review_comments += [{user:"u",body:"review claim",state:"COMMENTED",
        url:"https://github.com/o/r/pull/1#pullrequestreview-20",submitted_at:"t"}]
    | .inline_comments += [{user:"u",body:"inline claim",path:"a.js",line:1,
        url:"https://github.com/o/r/pull/1#discussion_r30",created_at:"t"}]' \
    "$DISPUTE_CONTEXT_ORIGINAL" > "$DISPUTE_CONTEXT_TMP"
DISPUTE_FINGERPRINT=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
    "$DISPUTE_CONTEXT_TMP")
jq --arg fingerprint "$DISPUTE_FINGERPRINT" \
    '.coverage.context_fingerprint = $fingerprint' \
    "$DISPUTE_CONTEXT_TMP" > "$AUTHORIZED_DIR/analysis-context.json"
jq --arg fingerprint "$DISPUTE_FINGERPRINT" '
    ._metadata.context_fingerprint = $fingerprint
    | .disputed_comments = [
        {thread_id:"PRRT_open",claim:"thread",why_incorrect:"fixture",confidence:"high"},
        {thread_id:"https://github.com/o/r/pull/1#issuecomment-10",claim:"issue",why_incorrect:"fixture",confidence:"high"},
        {thread_id:"https://github.com/o/r/pull/1#pullrequestreview-20",claim:"review",why_incorrect:"fixture",confidence:"high"},
        {thread_id:"https://github.com/o/r/pull/1#discussion_r30",claim:"inline",why_incorrect:"fixture",confidence:"high"}
    ]' "$HYBRID_SOURCE" > "$DISPUTE_SOURCE"
validate_candidate_contract "$AUTHORIZED_DIR" "$DISPUTE_SOURCE" >/dev/null
assert_jq "$DISPUTE_SOURCE" \
    '(.disputed_comments | length) == 4' \
    "selection accepts captured PRRT and non-thread comment references"
jq '.disputed_comments[1].thread_id = "https://github.com/o/r/pull/1#issuecomment-invented"' \
    "$DISPUTE_SOURCE" > "$UNKNOWN_DISPUTE_SOURCE"
rc=0
UNKNOWN_DISPUTE_OUT=$(validate_candidate_contract "$AUTHORIZED_DIR" \
    "$UNKNOWN_DISPUTE_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects dispute URLs absent from the fingerprinted context"
assert_contains "$UNKNOWN_DISPUTE_OUT" "fingerprinted context" \
    "unknown dispute references fail provenance validation"
jq '.issue_categories = [{
        finding_id:"captured-url-finding",name:"Captured URL finding",
        category:"logic_error",severity:"high",impact:"moderate",likelihood:"likely",
        severity_rationale:"fixture",verdict:"plausible",confidence:"high",
        description:"fixture",evidence:[{file:"a.js",line:1,detail:"fixture"}],
        thread_ids:["https://github.com/o/r/pull/1#issuecomment-10"],
        sources:["codex:orchestrator"]
    }]
    | .category_coverage |= map(if .category == "logic_error"
        then .verdict = "findings_reported" else . end)' \
    "$DISPUTE_SOURCE" > "$FINDING_URL_SOURCE"
rc=0
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$FINDING_URL_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "captured comment URLs remain invalid as finding thread IDs"
jq '.issue_categories[0].verdict = "confirmed"
    | .task_list = [{priority:"high",task:"URL-bearing task",
        finding_ids:["captured-url-finding"],
        thread_ids:["https://github.com/o/r/pull/1#issuecomment-10"],
        file:"a.js",line:1,suggested_fix:"fix",verification:"test"}]' \
    "$FINDING_URL_SOURCE" > "$TASK_URL_SOURCE"
rc=0
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$TASK_URL_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "captured comment URLs remain invalid as task thread IDs"
cp "$DISPUTE_CONTEXT_ORIGINAL" "$AUTHORIZED_DIR/analysis-context.json"

assert_jq "$AUTHORIZED_DIR/analysis-context.json" \
    '.coverage.code_access.state == "disabled"' \
    "the selection fixture records disabled repository code access"
NO_CODE_CONFIRMED_SOURCE="$AUTHORIZED_DIR/no-code-confirmed.json"
jq '.issue_categories = [{
        finding_id: "unverified-finding", name: "Unverified finding",
        category: "logic_error", severity: "high",
        impact: "moderate", likelihood: "likely", severity_rationale: "fixture",
        verdict: "confirmed", confidence: "high", description: "fixture",
        evidence: [{file:"a.js",line:1,detail:"fixture"}], thread_ids: ["PRRT_open"],
        sources: ["codex:orchestrator"]
    }]
    | .task_list = [{
        priority: "high", task: "Fix the verified defect",
        finding_ids: ["unverified-finding"], thread_ids: ["PRRT_open"],
        file: "a.js", line: 1, suggested_fix: "fix it", verification: "test it"
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
        code_access_workspace_fingerprint "$SELECTION_REPORT" "" working_tree)
jq --arg inspected_sha "$SELECTION_HEAD" --arg workspace_fingerprint "$SELECTION_WORKSPACE_FINGERPRINT" '
    del(.coverage.context_fingerprint)
    | .coverage.code_access.state = "enabled"
    | .coverage.code_access.reason = "explicit fixture override"
    | .coverage.code_access.inspected_sha = $inspected_sha
    | .coverage.code_access.revision_matches = false
    | .coverage.code_access.snapshot_source = "working_tree"
    | .coverage.code_access.workspace_fingerprint = $workspace_fingerprint
    | .unresolved_threads += [{thread_id:"PRRT_other",comments_complete:true,
        comment_identity:[]}]
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
assert_jq "$SELECTION_REPORT/analysis.json" \
    '.task_list[0].finding_ids == ["unverified-finding"]' \
    "a task mapped to a confirmed finding is selectable"

# A clean native result still claims that the immutable code snapshot was
# reviewed. Bind that claim to the same workspace fingerprint as a finding.
CLEAN_CODE_SOURCE="$SELECTION_REPORT/codex-analysis.json"
CLEAN_CODE_SAVED="$SELECTION_REPORT/claude-code-analysis.json"
jq '.issue_categories = []
    | .task_list = []
    | .disputed_comments = []
    | .category_coverage |= map(.verdict = "reviewed_none_found")' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$CLEAN_CODE_SOURCE"
cp "$CLEAN_CODE_SOURCE" "$CLEAN_CODE_SAVED"
jq 'del(._metadata.workspace_fingerprint)' \
    "$CLEAN_CODE_SAVED" > "$CLEAN_CODE_SOURCE"
rc=0
(cd "$SELECTION_REPO" && \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$CLEAN_CODE_SOURCE" >/dev/null 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "clean native analysis without the snapshot fingerprint is rejected"
jq '._metadata.workspace_fingerprint = "sha256:not-the-reviewed-workspace"' \
    "$CLEAN_CODE_SAVED" > "$CLEAN_CODE_SOURCE"
rc=0
(cd "$SELECTION_REPO" && \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$CLEAN_CODE_SOURCE" >/dev/null 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "clean native analysis with a mismatched snapshot fingerprint is rejected"
mv "$CLEAN_CODE_SAVED" "$CLEAN_CODE_SOURCE"
(cd "$SELECTION_REPO" && \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$CLEAN_CODE_SOURCE" >/dev/null)
assert_jq "$SELECTION_REPORT/analysis.json" \
    '(.issue_categories | length) == 0 and
     all(.category_coverage[]; .verdict == "reviewed_none_found")' \
    "clean native analysis binds its all-clear verdict to the reviewed snapshot"
(cd "$SELECTION_REPO" && \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" >/dev/null)
rm -f "$CLEAN_CODE_SOURCE"

FRACTIONAL_LINE_SOURCE="$SELECTION_REPORT/fractional-lines.json"
jq '.task_list[0].line = 1.5' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$FRACTIONAL_LINE_SOURCE"
rc=0
validate_candidate_contract "$SELECTION_REPORT" \
    "$FRACTIONAL_LINE_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selector line validation matches the schema integer contract"
rm -f "$FRACTIONAL_LINE_SOURCE"

for RELATIVE_REPORT in report ./report report/../report report/; do
    (cd "$SELECTION_REPO" && "$GH_PR_ENRICH" select-analysis \
        "$RELATIVE_REPORT" "$SELECTION_REPORT/hybrid-analysis.json" >/dev/null)
    assert_true "0" \
        "stable selection accepts report path spelling '$RELATIVE_REPORT'"
done
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "normalized relative selections leave no transaction residue"

# macOS exposes /tmp through the /private/tmp root alias. The held writer lock
# must be compared by its physical path so the selector can exclude only its
# own private replacement directory during final workspace revalidation.
mkdir -p "$TMP_ALIAS_SELECTION/report"
(cd "$TMP_ALIAS_SELECTION" && git init -q . && git config user.email t@t && \
    git config user.name t && echo stable > tracked.txt && git add tracked.txt && \
    git -c commit.gpgsign=false commit -qm init)
TMP_ALIAS_HEAD=$(git -C "$TMP_ALIAS_SELECTION" rev-parse HEAD)
cp "$AUTHORIZED_DIR/pr-summary.json" "$TMP_ALIAS_SELECTION/report/pr-summary.json"
TMP_ALIAS_WORKSPACE_FINGERPRINT=$(cd "$TMP_ALIAS_SELECTION" && \
    "$GH_PR_ENRICH" --test-call code_access_workspace_fingerprint \
        "$TMP_ALIAS_SELECTION/report")
jq --arg inspected_sha "$TMP_ALIAS_HEAD" \
    --arg workspace_fingerprint "$TMP_ALIAS_WORKSPACE_FINGERPRINT" '
    del(.coverage.context_fingerprint)
    | .coverage.code_access.state = "enabled"
    | .coverage.code_access.reason = "root-alias fixture"
    | .coverage.code_access.inspected_sha = $inspected_sha
    | .coverage.code_access.revision_matches = false
    | .coverage.code_access.workspace_fingerprint = $workspace_fingerprint
' "$SELECTION_CONTEXT_BASE" > "$TMP_ALIAS_SELECTION/report/context.tmp.json"
TMP_ALIAS_CONTEXT_FINGERPRINT=$(
    "$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
        "$TMP_ALIAS_SELECTION/report/context.tmp.json"
)
jq --arg fingerprint "$TMP_ALIAS_CONTEXT_FINGERPRINT" \
    '.coverage.context_fingerprint = $fingerprint' \
    "$TMP_ALIAS_SELECTION/report/context.tmp.json" \
    > "$TMP_ALIAS_SELECTION/report/analysis-context.json"
rm -f "$TMP_ALIAS_SELECTION/report/context.tmp.json"
jq --arg fingerprint "$TMP_ALIAS_CONTEXT_FINGERPRINT" \
    --arg workspace_fingerprint "$TMP_ALIAS_WORKSPACE_FINGERPRINT" '
    ._metadata.context_fingerprint = $fingerprint
    | ._metadata.workspace_fingerprint = $workspace_fingerprint
' "$SELECTION_SOURCE_BASE" > "$TMP_ALIAS_SELECTION/report/hybrid-analysis.json"
(cd "$TMP_ALIAS_SELECTION" && "$GH_PR_ENRICH" select-analysis \
    "$TMP_ALIAS_SELECTION/report" \
    "$TMP_ALIAS_SELECTION/report/hybrid-analysis.json" >/dev/null)
assert_true "$([ -f "$TMP_ALIAS_SELECTION/report/analysis.json" ] && echo 0 || echo 1)" \
    "stable selection accepts a platform root-alias report path"
assert_no_selection_transaction_residue "$TMP_ALIAS_SELECTION/report" \
    "root-alias selection leaves no transaction residue"

MISSING_TASK_LINK="$SELECTION_REPORT/missing-task-link.json"
jq 'del(.task_list[0].finding_ids)' "$SELECTION_REPORT/hybrid-analysis.json" \
    > "$MISSING_TASK_LINK"
rc=0
validate_candidate_contract "$SELECTION_REPORT" \
    "$MISSING_TASK_LINK" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects remediation tasks without finding linkage"

UNKNOWN_TASK_LINK="$SELECTION_REPORT/unknown-task-link.json"
jq '.task_list[0].finding_ids = ["invented-finding"]' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$UNKNOWN_TASK_LINK"
rc=0
validate_candidate_contract "$SELECTION_REPORT" \
    "$UNKNOWN_TASK_LINK" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects remediation tasks mapped to unknown findings"

DUPLICATE_FINDING_ID="$SELECTION_REPORT/duplicate-finding-id.json"
jq '.issue_categories += [.issue_categories[0]]' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$DUPLICATE_FINDING_ID"
rc=0
validate_candidate_contract "$SELECTION_REPORT" \
    "$DUPLICATE_FINDING_ID" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects duplicate finding linkage IDs"

EMPTY_FINDING_ID="$SELECTION_REPORT/empty-finding-id.json"
jq '.issue_categories[0].finding_id = "" | .task_list = []' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$EMPTY_FINDING_ID"
rc=0
validate_candidate_contract "$SELECTION_REPORT" \
    "$EMPTY_FINDING_ID" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects an empty finding linkage ID"

DUPLICATE_TASK_LINK="$SELECTION_REPORT/duplicate-task-link.json"
jq '.task_list[0].finding_ids += [.task_list[0].finding_ids[0]]' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$DUPLICATE_TASK_LINK"
rc=0
validate_candidate_contract "$SELECTION_REPORT" \
    "$DUPLICATE_TASK_LINK" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects duplicate task finding IDs"

EMPTY_TASK_LINK="$SELECTION_REPORT/empty-task-link.json"
jq '.task_list[0].finding_ids = [""]' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$EMPTY_TASK_LINK"
rc=0
validate_candidate_contract "$SELECTION_REPORT" \
    "$EMPTY_TASK_LINK" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects empty task finding IDs"

for UNVERIFIED_TASK_VERDICT in plausible refuted; do
    UNVERIFIED_TASK_SOURCE="$SELECTION_REPORT/$UNVERIFIED_TASK_VERDICT-task.json"
    jq --arg verdict "$UNVERIFIED_TASK_VERDICT" \
        '.issue_categories[0].verdict = $verdict' \
        "$SELECTION_REPORT/hybrid-analysis.json" > "$UNVERIFIED_TASK_SOURCE"
    rc=0
    validate_candidate_contract "$SELECTION_REPORT" \
        "$UNVERIFIED_TASK_SOURCE" >/dev/null 2>&1 || rc=$?
    assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
        "selection rejects tasks mapped to $UNVERIFIED_TASK_VERDICT findings"
done

MISSING_SYSTEMIC_LINK="$SELECTION_REPORT/missing-systemic-link.json"
jq '.systemic_issues = [{pattern:"fixture",evidence:["fixture"],
        recommendation:"fixture"}]' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$MISSING_SYSTEMIC_LINK"
rc=0
validate_candidate_contract "$SELECTION_REPORT" \
    "$MISSING_SYSTEMIC_LINK" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects systemic patterns without finding linkage"

SINGLE_SYSTEMIC_LINK="$SELECTION_REPORT/single-systemic-link.json"
jq '.systemic_issues = [{pattern:"fixture",
        finding_ids:[.issue_categories[0].finding_id],
        evidence:["fixture"],recommendation:"fixture"}]' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$SINGLE_SYSTEMIC_LINK"
rc=0
validate_candidate_contract "$SELECTION_REPORT" \
    "$SINGLE_SYSTEMIC_LINK" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects a one-finding systemic label"

EMPTY_SYSTEMIC_EVIDENCE="$SELECTION_REPORT/empty-systemic-evidence.json"
jq '.issue_categories += [(.issue_categories[0]
        | .finding_id = "second-confirmed-finding")]
    | .systemic_issues = [{pattern:"fixture",
        finding_ids:[.issue_categories[0].finding_id,
            .issue_categories[1].finding_id],
        evidence:[],recommendation:"fixture"}]' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$EMPTY_SYSTEMIC_EVIDENCE"
rc=0
validate_candidate_contract "$SELECTION_REPORT" \
    "$EMPTY_SYSTEMIC_EVIDENCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects systemic patterns without linking evidence"

for UNVERIFIED_SYSTEMIC_VERDICT in plausible refuted; do
    UNVERIFIED_SYSTEMIC_SOURCE="$SELECTION_REPORT/$UNVERIFIED_SYSTEMIC_VERDICT-systemic.json"
    jq --arg verdict "$UNVERIFIED_SYSTEMIC_VERDICT" '
        .issue_categories[0].verdict = $verdict
        | .issue_categories += [(.issue_categories[0]
            | .finding_id = "second-unverified-finding")]
        | .task_list = []
        | .systemic_issues = [{pattern:"fixture",
            finding_ids:[.issue_categories[0].finding_id,
                .issue_categories[1].finding_id],
            evidence:["fixture"],recommendation:"fixture"}]
    ' "$SELECTION_REPORT/hybrid-analysis.json" > "$UNVERIFIED_SYSTEMIC_SOURCE"
    rc=0
    validate_candidate_contract "$SELECTION_REPORT" \
        "$UNVERIFIED_SYSTEMIC_SOURCE" >/dev/null 2>&1 || rc=$?
    assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
        "selection rejects systemic patterns mapped to $UNVERIFIED_SYSTEMIC_VERDICT findings"
done

MIXED_SYSTEMIC_SOURCE="$SELECTION_REPORT/mixed-verdict-systemic.json"
jq '.issue_categories += [(.issue_categories[0]
        | .finding_id = "plausible-systemic-finding"
        | .verdict = "plausible")]
    | .systemic_issues = [{pattern:"fixture",
        finding_ids:[.issue_categories[0].finding_id,
            .issue_categories[1].finding_id],
        evidence:["fixture"],recommendation:"fixture"}]' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$MIXED_SYSTEMIC_SOURCE"
rc=0
validate_candidate_contract "$SELECTION_REPORT" \
    "$MIXED_SYSTEMIC_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects systemic patterns mixing confirmed and plausible links"

DUPLICATE_TASK_THREAD="$SELECTION_REPORT/duplicate-task-thread.json"
jq '.task_list += [(.task_list[0] | .task = "Second task for same thread")]' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$DUPLICATE_TASK_THREAD"
rc=0
validate_candidate_contract "$SELECTION_REPORT" \
    "$DUPLICATE_TASK_THREAD" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects one hosted thread assigned to multiple tasks"

MISMATCHED_TASK_THREAD="$SELECTION_REPORT/mismatched-task-thread.json"
jq '.task_list[0].thread_ids = ["PRRT_other"]' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$MISMATCHED_TASK_THREAD"
rc=0
validate_candidate_contract "$SELECTION_REPORT" \
    "$MISMATCHED_TASK_THREAD" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects task threads outside the mapped confirmed findings"

UNKNOWN_TASK_THREAD="$SELECTION_REPORT/unknown-task-thread.json"
jq '.task_list[0].thread_ids = ["PRRT_from_another_pr"]' \
    "$SELECTION_REPORT/hybrid-analysis.json" > "$UNKNOWN_TASK_THREAD"
rc=0
UNKNOWN_TASK_THREAD_OUT=$(validate_candidate_contract "$SELECTION_REPORT" \
    "$UNKNOWN_TASK_THREAD" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection keeps mutation-bearing task IDs restricted to captured PRRT threads"
assert_contains "$UNKNOWN_TASK_THREAD_OUT" "missing required findings or provenance" \
    "an unknown mutation-bearing thread fails selected-analysis validation"
rm -f "$MISSING_TASK_LINK" "$UNKNOWN_TASK_LINK" \
    "$DUPLICATE_FINDING_ID" "$EMPTY_FINDING_ID" \
    "$DUPLICATE_TASK_LINK" "$EMPTY_TASK_LINK" \
    "$SELECTION_REPORT/plausible-task.json" \
    "$SELECTION_REPORT/refuted-task.json" \
    "$MISSING_SYSTEMIC_LINK" \
    "$SELECTION_REPORT/plausible-systemic.json" \
    "$SELECTION_REPORT/refuted-systemic.json" \
    "$SINGLE_SYSTEMIC_LINK" "$EMPTY_SYSTEMIC_EVIDENCE" \
    "$MIXED_SYSTEMIC_SOURCE" "$DUPLICATE_TASK_THREAD" \
    "$MISMATCHED_TASK_THREAD" "$UNKNOWN_TASK_THREAD"

# Rendering can outlive the initial head/workspace checks. Mutate the tracked
# workspace exactly when the frozen candidate is copied into its private
# replacement directory; the final prepublication check must preserve every
# previously selected view.
LATE_WORKSPACE_STUBS="$TEST_OUTPUT_DIR/late-workspace-stubs"
LATE_WORKSPACE_MARKER="$TEST_OUTPUT_DIR/late-workspace-fired"
LATE_WORKSPACE_BACKUP="$TEST_OUTPUT_DIR/late-workspace-backup"
mkdir -p "$LATE_WORKSPACE_STUBS" "$LATE_WORKSPACE_BACKUP"
for LATE_VIEW in analysis.json analysis.md context-coverage.md \
        combined-data.json comprehensive-report.md; do
    [ ! -f "$SELECTION_REPORT/$LATE_VIEW" ] || \
        cp "$SELECTION_REPORT/$LATE_VIEW" "$LATE_WORKSPACE_BACKUP/$LATE_VIEW"
done
cat > "$LATE_WORKSPACE_STUBS/cp" << 'STUB'
#!/bin/bash
destination=""
for argument in "$@"; do destination="$argument"; done
case "$destination" in
    "$LATE_WORKSPACE_REPORT"/.selected-analysis-replacements.*/analysis.json)
        if [ ! -e "$LATE_WORKSPACE_MARKER" ]; then
            : > "$LATE_WORKSPACE_MARKER"
            printf '%s\n' late-selection-change >> "$LATE_WORKSPACE_TRACKED_FILE"
        fi
        ;;
esac
exec "$LATE_WORKSPACE_REAL_CP" "$@"
STUB
chmod +x "$LATE_WORKSPACE_STUBS/cp"
rc=0
LATE_WORKSPACE_OUT=$(cd "$SELECTION_REPO" && \
    env PATH="$LATE_WORKSPACE_STUBS:$PATH" \
    LATE_WORKSPACE_REPORT="$SELECTION_REPORT" \
    LATE_WORKSPACE_MARKER="$LATE_WORKSPACE_MARKER" \
    LATE_WORKSPACE_TRACKED_FILE="$SELECTION_REPO/tracked.txt" \
    LATE_WORKSPACE_REAL_CP="$(command -v cp)" \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ -e "$LATE_WORKSPACE_MARKER" ] && echo 0 || echo 1)" \
    "selection detects workspace drift introduced after rendering begins" \
    "$LATE_WORKSPACE_OUT"
assert_contains "$LATE_WORKSPACE_OUT" "Local workspace changed during selection" \
    "late workspace rejection identifies the prepublication boundary"
LATE_WORKSPACE_VIEWS_PRESERVED=true
for LATE_VIEW in analysis.json analysis.md context-coverage.md \
        combined-data.json comprehensive-report.md; do
    if [ -f "$LATE_WORKSPACE_BACKUP/$LATE_VIEW" ]; then
        cmp -s "$SELECTION_REPORT/$LATE_VIEW" \
            "$LATE_WORKSPACE_BACKUP/$LATE_VIEW" || \
            LATE_WORKSPACE_VIEWS_PRESERVED=false
    elif [ -e "$SELECTION_REPORT/$LATE_VIEW" ]; then
        LATE_WORKSPACE_VIEWS_PRESERVED=false
    fi
done
assert_true "$([ "$LATE_WORKSPACE_VIEWS_PRESERVED" = true ] && echo 0 || echo 1)" \
    "late workspace drift preserves every prior selected view"
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "late workspace rejection leaves no selection transaction residue"
git -C "$SELECTION_REPO" checkout -- tracked.txt

# Advance the hosted head only after private replacement staging. The second
# hosted check must invalidate the now-stale selected views and publish none of
# the staged candidate.
LATE_HEAD_STUBS="$TEST_OUTPUT_DIR/late-head-stubs"
LATE_HEAD_MARKER="$TEST_OUTPUT_DIR/late-head-fired"
LATE_HEAD_LOG="$TEST_OUTPUT_DIR/late-head-views.log"
mkdir -p "$LATE_HEAD_STUBS"
cat > "$LATE_HEAD_STUBS/cp" << 'STUB'
#!/bin/bash
destination=""
for argument in "$@"; do destination="$argument"; done
case "$destination" in
    "$LATE_HEAD_REPORT"/.selected-analysis-replacements.*/analysis.json)
        : > "$LATE_HEAD_MARKER"
        ;;
esac
exec "$LATE_HEAD_REAL_CP" "$@"
STUB
cat > "$LATE_HEAD_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr view" ]; then
    if [ -e "$LATE_HEAD_MARKER" ]; then
        printf '%s\n' new-hosted-head >> "$LATE_HEAD_LOG"
        PR_HEAD_OID=new-hosted-head exec "$LATE_HEAD_BASE_GH" "$@"
    fi
    printf '%s\n' abc123 >> "$LATE_HEAD_LOG"
fi
exec "$LATE_HEAD_BASE_GH" "$@"
STUB
chmod +x "$LATE_HEAD_STUBS/cp" "$LATE_HEAD_STUBS/gh"
rc=0
LATE_HEAD_OUT=$(cd "$SELECTION_REPO" && \
    env PATH="$LATE_HEAD_STUBS:$PATH" \
    LATE_HEAD_REPORT="$SELECTION_REPORT" \
    LATE_HEAD_MARKER="$LATE_HEAD_MARKER" LATE_HEAD_LOG="$LATE_HEAD_LOG" \
    LATE_HEAD_REAL_CP="$(command -v cp)" LATE_HEAD_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ -e "$LATE_HEAD_MARKER" ] && echo 0 || echo 1)" \
    "selection detects a hosted head advance after rendering begins" \
    "$LATE_HEAD_OUT"
assert_eq $'abc123\nnew-hosted-head' "$(cat "$LATE_HEAD_LOG")" \
    "selection checks the hosted head before and immediately after staging"
assert_contains "$LATE_HEAD_OUT" "Hosted PR revision changed during selection" \
    "late hosted-head rejection identifies the prepublication boundary"
assert_true "$([ ! -e "$SELECTION_REPORT/analysis.json" ] && echo 0 || echo 1)" \
    "late hosted-head drift invalidates stale selected artifacts"
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "late hosted-head rejection leaves no selection transaction residue"
(cd "$SELECTION_REPO" && "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
    "$SELECTION_REPORT/hybrid-analysis.json" >/dev/null)

# Keep the hosted head fixed, but add an issue comment after private replacement
# staging. The final discussion check must reject the candidate and invalidate
# the now-stale prior selection.
cp "$AUTHORIZED_CLAUDE_FIXTURE" "$SELECTION_REPORT/claude-analysis.json"
printf '%s\n' '# Stale Claude provider report' \
    > "$SELECTION_REPORT/claude-analysis.md"
jq -n --slurpfile selected "$SELECTION_REPORT/analysis.json" \
    --slurpfile provider "$AUTHORIZED_CLAUDE_FIXTURE" \
    '{base:true, analysis:$selected[0], analysis_context_coverage:{},
      claude_analysis:$provider[0]}' \
    > "$SELECTION_REPORT/combined-data.json"
LATE_DISCUSSION_STUBS="$TEST_OUTPUT_DIR/late-discussion-stubs"
LATE_DISCUSSION_MARKER="$TEST_OUTPUT_DIR/late-discussion-fired"
mkdir -p "$LATE_DISCUSSION_STUBS"
cat > "$LATE_DISCUSSION_STUBS/cp" << 'STUB'
#!/bin/bash
destination=""
for argument in "$@"; do destination="$argument"; done
case "$destination" in
    "$LATE_DISCUSSION_REPORT"/.selected-analysis-replacements.*/analysis.json)
        : > "$LATE_DISCUSSION_MARKER"
        ;;
esac
exec "$LATE_DISCUSSION_REAL_CP" "$@"
STUB
cat > "$LATE_DISCUSSION_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1" = "api" ] && [ "$2" != "graphql" ]; then
    case "$*" in
        *issues/o/r/issues/1/comments*|*repos/o/r/issues/1/comments*)
            if [ -e "$LATE_DISCUSSION_MARKER" ]; then
                cat << 'JSON'
[{"id":99,"body":"new same-head comment","user":{"login":"reviewer"},"created_at":"2026-01-02T00:00:00Z","updated_at":"2026-01-02T00:00:00Z","html_url":"https://github.com/o/r/pull/1#issuecomment-99"}]
JSON
                exit 0
            fi
            ;;
    esac
fi
exec "$LATE_DISCUSSION_BASE_GH" "$@"
STUB
chmod +x "$LATE_DISCUSSION_STUBS/cp" "$LATE_DISCUSSION_STUBS/gh"
rc=0
LATE_DISCUSSION_OUT=$(cd "$SELECTION_REPO" && \
    env PATH="$LATE_DISCUSSION_STUBS:$PATH" \
    LATE_DISCUSSION_REPORT="$SELECTION_REPORT" \
    LATE_DISCUSSION_MARKER="$LATE_DISCUSSION_MARKER" \
    LATE_DISCUSSION_REAL_CP="$(command -v cp)" \
    LATE_DISCUSSION_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ -e "$LATE_DISCUSSION_MARKER" ] && echo 0 || echo 1)" \
    "selection detects same-head discussion drift after rendering begins" \
    "$LATE_DISCUSSION_OUT"
assert_contains "$LATE_DISCUSSION_OUT" "GitHub discussion state changed during selection" \
    "late discussion rejection identifies the prepublication boundary"
assert_true "$([ ! -e "$SELECTION_REPORT/analysis.json" ] && echo 0 || echo 1)" \
    "late discussion drift invalidates stale selected artifacts"
assert_true "$([ ! -e "$SELECTION_REPORT/claude-analysis.json" ] && \
    [ ! -e "$SELECTION_REPORT/claude-analysis.md" ] && echo 0 || echo 1)" \
    "late discussion drift invalidates stale provider artifacts"
assert_jq "$SELECTION_REPORT/combined-data.json" \
    '(has("analysis") | not) and
     (has("analysis_context_coverage") | not) and
     (has("claude_analysis") | not)' \
    "late discussion drift removes every embedded stale analysis payload"
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "late discussion rejection leaves no selection transaction residue"
(cd "$SELECTION_REPO" && "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
    "$SELECTION_REPORT/hybrid-analysis.json" >/dev/null)

# PR and linked-issue requirements can change without a new commit or comment.
# A confirmed same-head intent change invalidates every stale selected view.
rc=0
LATE_INTENT_OUT=$(cd "$SELECTION_REPO" && \
    LIVE_INTENT_BODY="changed same-head requirements" \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection detects same-head PR intent drift before publication" \
    "$LATE_INTENT_OUT"
assert_contains "$LATE_INTENT_OUT" \
    "GitHub PR or linked-issue intent changed during selection" \
    "intent drift is identified at the final hosted-state boundary"
assert_true "$([ ! -e "$SELECTION_REPORT/analysis.json" ] && \
    [ ! -e "$SELECTION_REPORT/analysis.md" ] && echo 0 || echo 1)" \
    "confirmed intent drift invalidates stale selected views"
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "intent drift leaves no selection transaction residue"
(cd "$SELECTION_REPO" && "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
    "$SELECTION_REPORT/hybrid-analysis.json" >/dev/null)

# Intent must be checked again after the later discussion/check reads. Change
# the same-head PR body only after the first stabilized intent verification.
LATE_INTENT_WINDOW_STUBS="$TEST_OUTPUT_DIR/late-intent-window-stubs"
LATE_INTENT_WINDOW_COUNT="$TEST_OUTPUT_DIR/late-intent-window-count"
mkdir -p "$LATE_INTENT_WINDOW_STUBS"
cat > "$LATE_INTENT_WINDOW_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "api graphql" ]; then
    case "$*" in
        *AnalysisIntentSnapshot*)
            count=$(cat "$LATE_INTENT_WINDOW_COUNT" 2>/dev/null || echo 0)
            count=$((count + 1))
            printf '%s\n' "$count" > "$LATE_INTENT_WINDOW_COUNT"
            if [ "$count" -ge 3 ]; then
                LIVE_INTENT_BODY="changed after first intent verification" \
                    exec "$LATE_INTENT_WINDOW_BASE_GH" "$@"
            fi
            ;;
    esac
fi
exec "$LATE_INTENT_WINDOW_BASE_GH" "$@"
STUB
chmod +x "$LATE_INTENT_WINDOW_STUBS/gh"
rc=0
LATE_INTENT_WINDOW_OUT=$(cd "$SELECTION_REPO" && \
    env PATH="$LATE_INTENT_WINDOW_STUBS:$PATH" \
    LATE_INTENT_WINDOW_COUNT="$LATE_INTENT_WINDOW_COUNT" \
    LATE_INTENT_WINDOW_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && \
    [ "$(cat "$LATE_INTENT_WINDOW_COUNT" 2>/dev/null || echo 0)" -eq 4 ] && \
    echo 0 || echo 1)" \
    "selection repeats intent attestation after later hosted-state reads" \
    "$LATE_INTENT_WINDOW_OUT"
assert_contains "$LATE_INTENT_WINDOW_OUT" \
    "GitHub PR or linked-issue intent changed during selection" \
    "late intent-window drift is rejected at the final hosted boundary"
assert_true "$([ ! -e "$SELECTION_REPORT/analysis.json" ] && \
    [ ! -e "$SELECTION_REPORT/claude-analysis.json" ] && echo 0 || echo 1)" \
    "late intent-window drift invalidates selected and provider views"
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "late intent-window drift leaves no selection transaction residue"
(cd "$SELECTION_REPO" && "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
    "$SELECTION_REPORT/hybrid-analysis.json" >/dev/null)

# Keep the head and discussion fixed, but transition a check during discussion
# verification after replacement staging. The second stabilized checks read
# must close that window. Nonzero `gh pr checks` is normal for failing checks;
# parseable JSON must still be fingerprinted against the captured no-check state.
LATE_CHECKS_STUBS="$TEST_OUTPUT_DIR/late-checks-stubs"
LATE_CHECKS_MARKER="$TEST_OUTPUT_DIR/late-checks-fired"
LATE_CHECKS_CHANGED="$TEST_OUTPUT_DIR/late-checks-changed"
mkdir -p "$LATE_CHECKS_STUBS"
cat > "$LATE_CHECKS_STUBS/cp" << 'STUB'
#!/bin/bash
destination=""
for argument in "$@"; do destination="$argument"; done
case "$destination" in
    "$LATE_CHECKS_REPORT"/.selected-analysis-replacements.*/analysis.json)
        : > "$LATE_CHECKS_MARKER"
        ;;
esac
exec "$LATE_CHECKS_REAL_CP" "$@"
STUB
cat > "$LATE_CHECKS_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1" = "api" ] && [ "$2" != "graphql" ] && \
   [ -e "$LATE_CHECKS_MARKER" ] && [ ! -e "$LATE_CHECKS_CHANGED" ]; then
    : > "$LATE_CHECKS_CHANGED"
fi
if [ "$1 $2" = "pr checks" ] && [ -e "$LATE_CHECKS_CHANGED" ]; then
    cat << 'JSON'
[{"name":"unit-tests","state":"FAILURE","bucket":"fail","workflow":"tests","startedAt":"2026-01-01T00:00:00Z","completedAt":"2026-01-01T00:01:00Z","event":"pull_request","link":"https://ci/1","description":"failed"}]
JSON
    exit 1
fi
exec "$LATE_CHECKS_BASE_GH" "$@"
STUB
chmod +x "$LATE_CHECKS_STUBS/cp" "$LATE_CHECKS_STUBS/gh"
rc=0
LATE_CHECKS_OUT=$(cd "$SELECTION_REPO" && \
    env PATH="$LATE_CHECKS_STUBS:$PATH" \
    LATE_CHECKS_REPORT="$SELECTION_REPORT" \
    LATE_CHECKS_MARKER="$LATE_CHECKS_MARKER" \
    LATE_CHECKS_CHANGED="$LATE_CHECKS_CHANGED" \
    LATE_CHECKS_REAL_CP="$(command -v cp)" \
    LATE_CHECKS_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ -e "$LATE_CHECKS_MARKER" ] && \
    [ -e "$LATE_CHECKS_CHANGED" ] && echo 0 || echo 1)" \
    "selection detects checks drift during final discussion verification" \
    "$LATE_CHECKS_OUT"
assert_contains "$LATE_CHECKS_OUT" "GitHub checks state changed during selection" \
    "late checks rejection identifies the prepublication boundary"
assert_true "$([ ! -e "$SELECTION_REPORT/analysis.json" ] && echo 0 || echo 1)" \
    "late checks drift invalidates stale selected artifacts"
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "late checks rejection leaves no selection transaction residue"
(cd "$SELECTION_REPO" && "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
    "$SELECTION_REPORT/hybrid-analysis.json" >/dev/null)

# A checks command can print a complete JSON array and then hang. The managed
# timeout status must win over those bytes; otherwise two timed-out reads can
# masquerade as a stable hosted snapshot.
CHECKS_TIMEOUT_STUBS="$TEST_OUTPUT_DIR/checks-timeout-stubs"
CHECKS_TIMEOUT_CHILD_PID="$TEST_OUTPUT_DIR/checks-timeout-child-pid"
CHECKS_TIMEOUT_BACKUP="$TEST_OUTPUT_DIR/checks-timeout-backup"
mkdir -p "$CHECKS_TIMEOUT_STUBS" "$CHECKS_TIMEOUT_BACKUP"
for CHECKS_TIMEOUT_VIEW in analysis.json analysis.md context-coverage.md \
        combined-data.json comprehensive-report.md; do
    [ ! -f "$SELECTION_REPORT/$CHECKS_TIMEOUT_VIEW" ] || \
        cp "$SELECTION_REPORT/$CHECKS_TIMEOUT_VIEW" \
            "$CHECKS_TIMEOUT_BACKUP/$CHECKS_TIMEOUT_VIEW"
done
cat > "$CHECKS_TIMEOUT_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr checks" ]; then
    printf '[]\n'
    printf '%s\n' "$$" > "$CHECKS_TIMEOUT_CHILD_PID"
    trap '' TERM INT
    while true; do sleep 0.05; done
fi
exec "$CHECKS_TIMEOUT_BASE_GH" "$@"
STUB
chmod +x "$CHECKS_TIMEOUT_STUBS/gh"
rc=0
CHECKS_TIMEOUT_OUT=$(cd "$SELECTION_REPO" && \
    env PATH="$CHECKS_TIMEOUT_STUBS:$PATH" \
    GH_PR_ENRICH_TEST_REAL_GITHUB_SLEEP=true \
    GH_PR_ENRICH_GITHUB_TIMEOUT=1 \
    CHECKS_TIMEOUT_CHILD_PID="$CHECKS_TIMEOUT_CHILD_PID" \
    CHECKS_TIMEOUT_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ -s "$CHECKS_TIMEOUT_CHILD_PID" ] && echo 0 || echo 1)" \
    "a timed-out checks command cannot publish its parseable partial output"
CHECKS_TIMEOUT_PID=$(cat "$CHECKS_TIMEOUT_CHILD_PID" 2>/dev/null || echo "")
assert_true "$([ -n "$CHECKS_TIMEOUT_PID" ] && \
    ! kill -0 "$CHECKS_TIMEOUT_PID" 2>/dev/null && echo 0 || echo 1)" \
    "checks timeout reaps the GitHub child before selection returns"
assert_contains "$CHECKS_TIMEOUT_OUT" \
    "GitHub checks state could not be revalidated before selection" \
    "checks timeout is reported as unavailable rather than unchanged"
assert_selection_views_match "$SELECTION_REPORT" "$CHECKS_TIMEOUT_BACKUP" \
    "checks timeout preserves the prior selected views"
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "checks timeout leaves no selection transaction residue"

FINAL_BOUNDARY_BACKUP="$TEST_OUTPUT_DIR/final-boundary-backup"
mkdir -p "$FINAL_BOUNDARY_BACKUP"
for FINAL_VIEW in analysis.json analysis.md context-coverage.md \
        combined-data.json comprehensive-report.md; do
    [ ! -f "$SELECTION_REPORT/$FINAL_VIEW" ] || \
        cp "$SELECTION_REPORT/$FINAL_VIEW" "$FINAL_BOUNDARY_BACKUP/$FINAL_VIEW"
done

# The final hosted request sits between two local-state validations. Mutations
# made while that request is in flight must be detected after the unchanged
# hosted head returns and before any selected view is published.
FINAL_LOCAL_RACE_STUBS="$TEST_OUTPUT_DIR/final-local-race-stubs"
FINAL_LOCAL_RACE_COUNT="$TEST_OUTPUT_DIR/final-local-race-count"
FINAL_CONTEXT_BACKUP="$TEST_OUTPUT_DIR/final-context-backup.json"
mkdir -p "$FINAL_LOCAL_RACE_STUBS"
cat > "$FINAL_LOCAL_RACE_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr view" ]; then
    count=$(cat "$FINAL_LOCAL_RACE_COUNT" 2>/dev/null || echo 0)
    count=$((count + 1))
    printf '%s\n' "$count" > "$FINAL_LOCAL_RACE_COUNT"
    if [ "$count" -eq 2 ]; then
        case "$FINAL_LOCAL_RACE_KIND" in
            workspace)
                printf '%s\n' changed-during-hosted-check >> \
                    "$FINAL_LOCAL_RACE_TRACKED"
                ;;
            context)
                "$FINAL_LOCAL_RACE_JQ" \
                    '.pr.title = ((.pr.title // "") + " changed")' \
                    "$FINAL_LOCAL_RACE_CONTEXT" \
                    > "$FINAL_LOCAL_RACE_CONTEXT.tmp"
                "$FINAL_LOCAL_RACE_MV" "$FINAL_LOCAL_RACE_CONTEXT.tmp" \
                    "$FINAL_LOCAL_RACE_CONTEXT"
                ;;
        esac
    fi
fi
exec "$FINAL_LOCAL_RACE_BASE_GH" "$@"
STUB
chmod +x "$FINAL_LOCAL_RACE_STUBS/gh"

rc=0
FINAL_WORKSPACE_RACE_OUT=$(cd "$SELECTION_REPO" && \
    env PATH="$FINAL_LOCAL_RACE_STUBS:$PATH" \
    FINAL_LOCAL_RACE_KIND=workspace \
    FINAL_LOCAL_RACE_COUNT="$FINAL_LOCAL_RACE_COUNT" \
    FINAL_LOCAL_RACE_TRACKED="$SELECTION_REPO/tracked.txt" \
    FINAL_LOCAL_RACE_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ "$(cat "$FINAL_LOCAL_RACE_COUNT")" = 2 ] && echo 0 || echo 1)" \
    "selection rejects workspace drift during the final hosted-head lookup"
assert_contains "$FINAL_WORKSPACE_RACE_OUT" \
    "Local workspace changed during the final hosted-head check" \
    "final hosted-head workspace drift names the stale boundary"
assert_selection_views_match "$SELECTION_REPORT" "$FINAL_BOUNDARY_BACKUP" \
    "final hosted-head workspace drift preserves prior selected views"
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "final hosted-head workspace drift leaves no transaction residue"
git -C "$SELECTION_REPO" checkout -- tracked.txt

cp "$SELECTION_REPORT/analysis-context.json" "$FINAL_CONTEXT_BACKUP"
rm -f "$FINAL_LOCAL_RACE_COUNT"
rc=0
FINAL_CONTEXT_RACE_OUT=$(cd "$SELECTION_REPO" && \
    env PATH="$FINAL_LOCAL_RACE_STUBS:$PATH" \
    FINAL_LOCAL_RACE_KIND=context \
    FINAL_LOCAL_RACE_COUNT="$FINAL_LOCAL_RACE_COUNT" \
    FINAL_LOCAL_RACE_CONTEXT="$SELECTION_REPORT/analysis-context.json" \
    FINAL_LOCAL_RACE_JQ="$(command -v jq)" \
    FINAL_LOCAL_RACE_MV="$(command -v mv)" \
    FINAL_LOCAL_RACE_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ "$(cat "$FINAL_LOCAL_RACE_COUNT")" = 2 ] && echo 0 || echo 1)" \
    "selection rejects context drift during the final hosted-head lookup"
assert_contains "$FINAL_CONTEXT_RACE_OUT" \
    "Analysis context changed during the final hosted-head check" \
    "final hosted-head context drift names the stale boundary"
assert_selection_views_match "$SELECTION_REPORT" "$FINAL_BOUNDARY_BACKUP" \
    "final hosted-head context drift preserves prior selected views"
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "final hosted-head context drift leaves no transaction residue"
mv "$FINAL_CONTEXT_BACKUP" "$SELECTION_REPORT/analysis-context.json"

# A transient failure of the final hosted-head lookup fails closed without
# deleting the previously valid selected views.
UNAVAILABLE_HEAD_STUBS="$TEST_OUTPUT_DIR/unavailable-head-stubs"
UNAVAILABLE_HEAD_MARKER="$TEST_OUTPUT_DIR/unavailable-head-marker"
mkdir -p "$UNAVAILABLE_HEAD_STUBS"
cat > "$UNAVAILABLE_HEAD_STUBS/cp" << 'STUB'
#!/bin/bash
destination=""
for argument in "$@"; do destination="$argument"; done
case "$destination" in
    "$UNAVAILABLE_HEAD_REPORT"/.selected-analysis-replacements.*/analysis.json)
        : > "$UNAVAILABLE_HEAD_MARKER"
        ;;
esac
exec "$UNAVAILABLE_HEAD_REAL_CP" "$@"
STUB
cat > "$UNAVAILABLE_HEAD_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr view" ] && [ -e "$UNAVAILABLE_HEAD_MARKER" ]; then
    if [ "${INCOMPLETE_REVISION_RESPONSE:-}" = true ]; then
        printf '%s\n' '{"headRefOid":"abc123"}'
        exit 0
    fi
    exit 91
fi
exec "$UNAVAILABLE_HEAD_BASE_GH" "$@"
STUB
chmod +x "$UNAVAILABLE_HEAD_STUBS/cp" "$UNAVAILABLE_HEAD_STUBS/gh"
rc=0
UNAVAILABLE_HEAD_OUT=$(cd "$SELECTION_REPO" && \
    env PATH="$UNAVAILABLE_HEAD_STUBS:$PATH" \
    UNAVAILABLE_HEAD_REPORT="$SELECTION_REPORT" \
    UNAVAILABLE_HEAD_MARKER="$UNAVAILABLE_HEAD_MARKER" \
    UNAVAILABLE_HEAD_REAL_CP="$(command -v cp)" \
    UNAVAILABLE_HEAD_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ -e "$UNAVAILABLE_HEAD_MARKER" ] && echo 0 || echo 1)" \
    "a final hosted-head lookup failure rejects selection"
assert_contains "$UNAVAILABLE_HEAD_OUT" "could not be revalidated during selection" \
    "hosted-head lookup failure is distinct from confirmed drift"
assert_selection_views_match "$SELECTION_REPORT" "$FINAL_BOUNDARY_BACKUP" \
    "hosted-head lookup failure preserves every prior selected view"
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "hosted-head lookup failure leaves no transaction residue"

# A syntactically valid response that omits requested base identity is also
# unavailable, not a confirmed mismatch. It must preserve prior selected views.
rm -f "$UNAVAILABLE_HEAD_MARKER"
rc=0
INCOMPLETE_REVISION_OUT=$(cd "$SELECTION_REPO" && \
    env PATH="$UNAVAILABLE_HEAD_STUBS:$PATH" \
    INCOMPLETE_REVISION_RESPONSE=true \
    UNAVAILABLE_HEAD_REPORT="$SELECTION_REPORT" \
    UNAVAILABLE_HEAD_MARKER="$UNAVAILABLE_HEAD_MARKER" \
    UNAVAILABLE_HEAD_REAL_CP="$(command -v cp)" \
    UNAVAILABLE_HEAD_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ -e "$UNAVAILABLE_HEAD_MARKER" ] && echo 0 || echo 1)" \
    "an incomplete successful revision response rejects selection"
assert_contains "$INCOMPLETE_REVISION_OUT" \
    "could not be revalidated during selection" \
    "an incomplete revision response remains unavailable"
assert_selection_views_match "$SELECTION_REPORT" "$FINAL_BOUNDARY_BACKUP" \
    "an incomplete revision response preserves every prior selected view"
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "an incomplete revision response leaves no transaction residue"

# Direct writes into the private staging directory are outside the cooperative
# writer protocol. Bind every staged file by exact set, mode, and digest before
# and inside publication so such a write cannot reach selected views.
TAMPER_STAGED_STUBS="$TEST_OUTPUT_DIR/tamper-staged-stubs"
TAMPER_STAGED_MARKER="$TEST_OUTPUT_DIR/tamper-staged-marker"
mkdir -p "$TAMPER_STAGED_STUBS"
cat > "$TAMPER_STAGED_STUBS/cp" << 'STUB'
#!/bin/bash
destination=""
for argument in "$@"; do destination="$argument"; done
case "$destination" in
    "$TAMPER_STAGED_REPORT"/.selected-analysis-replacements.*/analysis.json)
        : > "$TAMPER_STAGED_MARKER"
        ;;
esac
exec "$TAMPER_STAGED_REAL_CP" "$@"
STUB
cat > "$TAMPER_STAGED_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr view" ] && [ -e "$TAMPER_STAGED_MARKER" ]; then
    for candidate in "$TAMPER_STAGED_REPORT"/.selected-analysis-replacements.*/analysis.json; do
        [ -f "$candidate" ] || continue
        printf '\n' >> "$candidate"
    done
fi
exec "$TAMPER_STAGED_BASE_GH" "$@"
STUB
chmod +x "$TAMPER_STAGED_STUBS/cp" "$TAMPER_STAGED_STUBS/gh"
rc=0
TAMPER_STAGED_OUT=$(cd "$SELECTION_REPO" && \
    env PATH="$TAMPER_STAGED_STUBS:$PATH" \
    TAMPER_STAGED_REPORT="$SELECTION_REPORT" \
    TAMPER_STAGED_MARKER="$TAMPER_STAGED_MARKER" \
    TAMPER_STAGED_REAL_CP="$(command -v cp)" \
    TAMPER_STAGED_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ -e "$TAMPER_STAGED_MARKER" ] && echo 0 || echo 1)" \
    "a staged replacement mutation rejects selection"
assert_contains "$TAMPER_STAGED_OUT" "Staged selected-analysis views changed" \
    "staged replacement mutation is reported at the publication boundary"
assert_selection_views_match "$SELECTION_REPORT" "$FINAL_BOUNDARY_BACKUP" \
    "staged replacement mutation preserves every prior selected view"
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "staged replacement mutation leaves no transaction residue"

# The publication transaction rechecks the exact staged set between live-view
# quarantine moves. A new entry after the first move must roll the transaction
# back rather than publish from an untrusted replacement directory.
QUARANTINE_IDENTITY_STUBS="$TEST_OUTPUT_DIR/quarantine-identity-stubs"
QUARANTINE_IDENTITY_MARKER="$TEST_OUTPUT_DIR/quarantine-identity-marker"
mkdir -p "$QUARANTINE_IDENTITY_STUBS"
cat > "$QUARANTINE_IDENTITY_STUBS/mv" << 'STUB'
#!/bin/bash
"$QUARANTINE_IDENTITY_REAL_MV" "$@" || exit $?
destination=""
for argument in "$@"; do destination="$argument"; done
case "$destination" in
    "$QUARANTINE_IDENTITY_REPORT"/.selected-analysis-quarantine.*/analysis.json)
        if [ ! -e "$QUARANTINE_IDENTITY_MARKER" ]; then
            : > "$QUARANTINE_IDENTITY_MARKER"
            for replacement in \
                    "$QUARANTINE_IDENTITY_REPORT"/.selected-analysis-replacements.*; do
                [ -d "$replacement" ] || continue
                case "$QUARANTINE_IDENTITY_KIND" in
                    unexpected) : > "$replacement/unexpected-entry" ;;
                    mode) "$QUARANTINE_IDENTITY_CHMOD" 000 \
                        "$replacement/analysis.md" ;;
                    nonregular)
                        "$QUARANTINE_IDENTITY_RM" -f \
                            "$replacement/analysis.md"
                        "$QUARANTINE_IDENTITY_MKDIR" \
                            "$replacement/analysis.md"
                        ;;
                esac
            done
        fi
        ;;
esac
STUB
chmod +x "$QUARANTINE_IDENTITY_STUBS/mv"
rc=0
QUARANTINE_IDENTITY_OUT=$(cd "$SELECTION_REPO" && \
    env PATH="$QUARANTINE_IDENTITY_STUBS:$PATH" \
    QUARANTINE_IDENTITY_KIND=unexpected \
    QUARANTINE_IDENTITY_REPORT="$SELECTION_REPORT" \
    QUARANTINE_IDENTITY_MARKER="$QUARANTINE_IDENTITY_MARKER" \
    QUARANTINE_IDENTITY_REAL_MV="$(command -v mv)" \
    QUARANTINE_IDENTITY_CHMOD="$(command -v chmod)" \
    QUARANTINE_IDENTITY_RM="$(command -v rm)" \
    QUARANTINE_IDENTITY_MKDIR="$(command -v mkdir)" \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
: "$QUARANTINE_IDENTITY_OUT"
assert_true "$([ "$rc" -ne 0 ] && [ -e "$QUARANTINE_IDENTITY_MARKER" ] && echo 0 || echo 1)" \
    "selection rejects a replacement-set change during quarantine"
assert_selection_views_match "$SELECTION_REPORT" "$FINAL_BOUNDARY_BACKUP" \
    "quarantine-time replacement mutation rolls back every selected view"
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "quarantine-time replacement mutation leaves no transaction residue"

for QUARANTINE_IDENTITY_KIND in mode nonregular; do
    rm -f "$QUARANTINE_IDENTITY_MARKER"
    rc=0
    (cd "$SELECTION_REPO" && \
        env PATH="$QUARANTINE_IDENTITY_STUBS:$PATH" \
        QUARANTINE_IDENTITY_KIND="$QUARANTINE_IDENTITY_KIND" \
        QUARANTINE_IDENTITY_REPORT="$SELECTION_REPORT" \
        QUARANTINE_IDENTITY_MARKER="$QUARANTINE_IDENTITY_MARKER" \
        QUARANTINE_IDENTITY_REAL_MV="$(command -v mv)" \
        QUARANTINE_IDENTITY_CHMOD="$(command -v chmod)" \
        QUARANTINE_IDENTITY_RM="$(command -v rm)" \
        QUARANTINE_IDENTITY_MKDIR="$(command -v mkdir)" \
        "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
            "$SELECTION_REPORT/hybrid-analysis.json" >/dev/null 2>&1) || rc=$?
    assert_true "$([ "$rc" -ne 0 ] && \
        [ -e "$QUARANTINE_IDENTITY_MARKER" ] && echo 0 || echo 1)" \
        "selection rejects a $QUARANTINE_IDENTITY_KIND staged replacement"
    assert_selection_views_match "$SELECTION_REPORT" "$FINAL_BOUNDARY_BACKUP" \
        "$QUARANTINE_IDENTITY_KIND replacement rollback preserves selected views"
    assert_no_selection_transaction_residue "$SELECTION_REPORT" \
        "$QUARANTINE_IDENTITY_KIND replacement rollback leaves no residue"
done

# A replacement can also change after its first hard link is published. The
# final byte/mode identity check must detect that aliasing mutation and roll
# every live view back to its prepublication bytes.
LINK_IDENTITY_STUBS="$TEST_OUTPUT_DIR/link-identity-stubs"
LINK_IDENTITY_MARKER="$TEST_OUTPUT_DIR/link-identity-marker"
mkdir -p "$LINK_IDENTITY_STUBS"
cat > "$LINK_IDENTITY_STUBS/ln" << 'STUB'
#!/bin/bash
"$LINK_IDENTITY_REAL_LN" "$@" || exit $?
case "$1:$2" in
    "$LINK_IDENTITY_REPORT"/.selected-analysis-replacements.*/analysis.json:"$LINK_IDENTITY_REPORT"/analysis.json)
        if [ ! -e "$LINK_IDENTITY_MARKER" ]; then
            : > "$LINK_IDENTITY_MARKER"
            case "$LINK_IDENTITY_KIND" in
                bytes) printf '\n' >> "$1" ;;
                missing) "$LINK_IDENTITY_REAL_RM" -f "$1" ;;
                nonregular)
                    "$LINK_IDENTITY_REAL_RM" -f "$1"
                    "$LINK_IDENTITY_REAL_MKDIR" "$1"
                    ;;
                symlink)
                    "$LINK_IDENTITY_REAL_RM" -f "$1"
                    "$LINK_IDENTITY_REAL_LN" -s "$2" "$1"
                    ;;
            esac
        fi
        ;;
esac
STUB
chmod +x "$LINK_IDENTITY_STUBS/ln"
rc=0
LINK_IDENTITY_OUT=$(cd "$SELECTION_REPO" && \
    env PATH="$LINK_IDENTITY_STUBS:$PATH" \
    LINK_IDENTITY_KIND=bytes \
    LINK_IDENTITY_REPORT="$SELECTION_REPORT" \
    LINK_IDENTITY_MARKER="$LINK_IDENTITY_MARKER" \
    LINK_IDENTITY_REAL_LN="$(command -v ln)" \
    LINK_IDENTITY_REAL_RM="$(command -v rm)" \
    LINK_IDENTITY_REAL_MKDIR="$(command -v mkdir)" \
    "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
        "$SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
: "$LINK_IDENTITY_OUT"
assert_true "$([ "$rc" -ne 0 ] && [ -e "$LINK_IDENTITY_MARKER" ] && echo 0 || echo 1)" \
    "selection rejects replacement bytes changed after the first link"
assert_selection_views_match "$SELECTION_REPORT" "$FINAL_BOUNDARY_BACKUP" \
    "link-time replacement mutation rolls back every selected view"
assert_no_selection_transaction_residue "$SELECTION_REPORT" \
    "link-time replacement mutation leaves no transaction residue"

for LINK_IDENTITY_KIND in missing nonregular symlink; do
    rm -f "$LINK_IDENTITY_MARKER"
    rc=0
    (cd "$SELECTION_REPO" && \
        env PATH="$LINK_IDENTITY_STUBS:$PATH" \
        LINK_IDENTITY_KIND="$LINK_IDENTITY_KIND" \
        LINK_IDENTITY_REPORT="$SELECTION_REPORT" \
        LINK_IDENTITY_MARKER="$LINK_IDENTITY_MARKER" \
        LINK_IDENTITY_REAL_LN="$(command -v ln)" \
        LINK_IDENTITY_REAL_RM="$(command -v rm)" \
        LINK_IDENTITY_REAL_MKDIR="$(command -v mkdir)" \
        "$GH_PR_ENRICH" select-analysis "$SELECTION_REPORT" \
            "$SELECTION_REPORT/hybrid-analysis.json" >/dev/null 2>&1) || rc=$?
    assert_true "$([ "$rc" -ne 0 ] && \
        [ -e "$LINK_IDENTITY_MARKER" ] && echo 0 || echo 1)" \
        "selection rejects a post-link $LINK_IDENTITY_KIND replacement"
    assert_selection_views_match "$SELECTION_REPORT" "$FINAL_BOUNDARY_BACKUP" \
        "post-link $LINK_IDENTITY_KIND rollback preserves selected views"
    assert_no_selection_transaction_residue "$SELECTION_REPORT" \
        "post-link $LINK_IDENTITY_KIND rollback leaves no residue"
done

# The initial hosted-head verification runs before writer-lock acquisition, but
# it is still an owned, bounded external command. A stalled lookup must time out
# without creating a lock or leaving any process-group member behind.
PRELOCK_HEAD_STUBS="$TEST_OUTPUT_DIR/prelock-head-stubs"
PRELOCK_HEAD_READY="$TEST_OUTPUT_DIR/prelock-head-ready"
PRELOCK_HEAD_CHILD_PID="$TEST_OUTPUT_DIR/prelock-head-child-pid"
PRELOCK_HEAD_DESCENDANT_PID="$TEST_OUTPUT_DIR/prelock-head-descendant-pid"
PRELOCK_SELECTION_REPO="$TEST_OUTPUT_DIR/prelock-selection-workspace"
cp -R "$SELECTION_REPO" "$PRELOCK_SELECTION_REPO"
PRELOCK_SELECTION_REPORT="$PRELOCK_SELECTION_REPO/report"
mkdir -p "$PRELOCK_HEAD_STUBS"
cat > "$PRELOCK_HEAD_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr view" ]; then
    printf '%s\n' "$$" > "$PRELOCK_HEAD_CHILD_PID"
    (
        trap '' TERM INT
        while :; do sleep 1; done
    ) &
    printf '%s\n' "$!" > "$PRELOCK_HEAD_DESCENDANT_PID"
    : > "$PRELOCK_HEAD_READY"
    trap 'exit 0' TERM
    while :; do sleep 1; done
fi
exec "$PRELOCK_HEAD_BASE_GH" "$@"
STUB
chmod +x "$PRELOCK_HEAD_STUBS/gh"
BLOCKED_HEAD_CHILD_PID_FILE="$PRELOCK_HEAD_CHILD_PID"
BLOCKED_HEAD_DESCENDANT_PID_FILE="$PRELOCK_HEAD_DESCENDANT_PID"
rc=0
PRELOCK_HEAD_OUT=$(cd "$PRELOCK_SELECTION_REPO" && \
    env PATH="$PRELOCK_HEAD_STUBS:$PATH" \
    GH_PR_ENRICH_GITHUB_TIMEOUT=1 \
    PRELOCK_HEAD_BASE_GH="$STUB_DIR/gh" \
    PRELOCK_HEAD_READY="$PRELOCK_HEAD_READY" \
    PRELOCK_HEAD_CHILD_PID="$PRELOCK_HEAD_CHILD_PID" \
    PRELOCK_HEAD_DESCENDANT_PID="$PRELOCK_HEAD_DESCENDANT_PID" \
    "$GH_PR_ENRICH" select-analysis "$PRELOCK_SELECTION_REPORT" \
        "$PRELOCK_SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
PRELOCK_CHILD_PID=$(cat "$PRELOCK_HEAD_CHILD_PID" 2>/dev/null || echo "")
PRELOCK_DESCENDANT_PID=$(cat \
    "$PRELOCK_HEAD_DESCENDANT_PID" 2>/dev/null || echo "")
assert_true "$([ "$rc" -ne 0 ] && [ -e "$PRELOCK_HEAD_READY" ] && echo 0 || echo 1)" \
    "the initial hosted-head lookup enforces its managed timeout"
assert_contains "$PRELOCK_HEAD_OUT" "could not be revalidated before selection" \
    "the pre-lock timeout preserves unavailable hosted-head semantics"
assert_process_reaped "$PRELOCK_CHILD_PID" \
    "the pre-lock timeout reaps its direct GitHub child"
assert_process_reaped "$PRELOCK_DESCENDANT_PID" \
    "the pre-lock timeout reaps TERM-ignoring descendants"
assert_selection_views_match "$PRELOCK_SELECTION_REPORT" \
    "$FINAL_BOUNDARY_BACKUP" \
    "the pre-lock timeout preserves every prior selected view"
assert_no_selection_transaction_residue "$PRELOCK_SELECTION_REPORT" \
    "the pre-lock timeout creates no selection transaction residue"

# A concurrent publisher can replace selected views while the initial hosted
# head lookup is in flight. Deferred invalidation is identity-scoped to the
# views that existed when this stale selection started.
PRELOCK_DRIFT_STUBS="$TEST_OUTPUT_DIR/prelock-drift-stubs"
PRELOCK_DRIFT_REPO="$TEST_OUTPUT_DIR/prelock-drift-workspace"
PRELOCK_DRIFT_MARKER="$TEST_OUTPUT_DIR/prelock-drift-fired"
cp -R "$SELECTION_REPO" "$PRELOCK_DRIFT_REPO"
PRELOCK_DRIFT_REPORT="$PRELOCK_DRIFT_REPO/report"
mkdir -p "$PRELOCK_DRIFT_STUBS"
cat > "$PRELOCK_DRIFT_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr view" ] && [ ! -e "$PRELOCK_DRIFT_MARKER" ]; then
    jq '.process_improvements[0].suggestion = "concurrent newer publication"' \
        "$PRELOCK_DRIFT_REPORT/analysis.json" \
        > "$PRELOCK_DRIFT_REPORT/analysis.concurrent.json"
    mv "$PRELOCK_DRIFT_REPORT/analysis.concurrent.json" \
        "$PRELOCK_DRIFT_REPORT/analysis.json"
    : > "$PRELOCK_DRIFT_MARKER"
    PR_HEAD_OID=new-hosted-head exec "$PRELOCK_DRIFT_BASE_GH" "$@"
fi
exec "$PRELOCK_DRIFT_BASE_GH" "$@"
STUB
chmod +x "$PRELOCK_DRIFT_STUBS/gh"
rc=0
PRELOCK_DRIFT_OUT=$(cd "$PRELOCK_DRIFT_REPO" && \
    env PATH="$PRELOCK_DRIFT_STUBS:$PATH" \
    PRELOCK_DRIFT_REPORT="$PRELOCK_DRIFT_REPORT" \
    PRELOCK_DRIFT_MARKER="$PRELOCK_DRIFT_MARKER" \
    PRELOCK_DRIFT_BASE_GH="$STUB_DIR/gh" \
    "$GH_PR_ENRICH" select-analysis "$PRELOCK_DRIFT_REPORT" \
        "$PRELOCK_DRIFT_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && [ -e "$PRELOCK_DRIFT_MARKER" ] && echo 0 || echo 1)" \
    "initial hosted-head drift rejects the stale selection"
assert_jq "$PRELOCK_DRIFT_REPORT/analysis.json" \
    '.process_improvements[0].suggestion == "concurrent newer publication"' \
    "initial hosted-head invalidation preserves a newer concurrent publication"
assert_contains "$PRELOCK_DRIFT_OUT" "newer publication was preserved" \
    "identity-scoped pre-lock invalidation reports the preserved publication"
assert_no_selection_transaction_residue "$PRELOCK_DRIFT_REPORT" \
    "pre-lock hosted-head drift leaves no selection transaction residue"

# The standalone selector owns and bounds its final GitHub child while holding
# the writer lock. Cancellation terminates the child before releasing the lock.
BLOCKED_HEAD_STUBS="$TEST_OUTPUT_DIR/blocked-head-stubs"
BLOCKED_HEAD_MARKER="$TEST_OUTPUT_DIR/blocked-head-marker"
BLOCKED_HEAD_READY="$TEST_OUTPUT_DIR/blocked-head-ready"
BLOCKED_HEAD_CHILD_PID="$TEST_OUTPUT_DIR/blocked-head-child-pid"
BLOCKED_HEAD_DESCENDANT_PID="$TEST_OUTPUT_DIR/blocked-head-descendant-pid"
BLOCKED_HEAD_OUT="$TEST_OUTPUT_DIR/blocked-head.out"
BLOCKED_HEAD_CHILD_PID_FILE="$BLOCKED_HEAD_CHILD_PID"
BLOCKED_HEAD_DESCENDANT_PID_FILE="$BLOCKED_HEAD_DESCENDANT_PID"
mkdir -p "$BLOCKED_HEAD_STUBS"
cp "$UNAVAILABLE_HEAD_STUBS/cp" "$BLOCKED_HEAD_STUBS/cp"
cat > "$BLOCKED_HEAD_STUBS/gh" << 'STUB'
#!/bin/bash
if [ "$1 $2" = "pr view" ] && [ -e "$UNAVAILABLE_HEAD_MARKER" ]; then
    printf '%s\n' "$$" > "$BLOCKED_HEAD_CHILD_PID"
    (
        trap '' TERM INT
        while :; do sleep 1; done
    ) &
    printf '%s\n' "$!" > "$BLOCKED_HEAD_DESCENDANT_PID"
    : > "$BLOCKED_HEAD_READY"
    trap 'exit 0' TERM
    while :; do sleep 1; done
fi
exec "$UNAVAILABLE_HEAD_BASE_GH" "$@"
STUB
chmod +x "$BLOCKED_HEAD_STUBS/cp" "$BLOCKED_HEAD_STUBS/gh"
TERM_SELECTION_REPO="$TEST_OUTPUT_DIR/term-selection-workspace"
cp -R "$SELECTION_REPO" "$TERM_SELECTION_REPO"
TERM_SELECTION_REPORT="$TERM_SELECTION_REPO/report"
(cd "$TERM_SELECTION_REPO" && exec env PATH="$BLOCKED_HEAD_STUBS:$PATH" \
    UNAVAILABLE_HEAD_REPORT="$TERM_SELECTION_REPORT" \
    UNAVAILABLE_HEAD_MARKER="$BLOCKED_HEAD_MARKER" \
    UNAVAILABLE_HEAD_REAL_CP="$(command -v cp)" \
    UNAVAILABLE_HEAD_BASE_GH="$STUB_DIR/gh" \
    BLOCKED_HEAD_READY="$BLOCKED_HEAD_READY" \
    BLOCKED_HEAD_CHILD_PID="$BLOCKED_HEAD_CHILD_PID" \
    BLOCKED_HEAD_DESCENDANT_PID="$BLOCKED_HEAD_DESCENDANT_PID" \
    "$GH_PR_ENRICH" select-analysis "$TERM_SELECTION_REPORT" \
        "$TERM_SELECTION_REPORT/hybrid-analysis.json") > "$BLOCKED_HEAD_OUT" 2>&1 &
RUNTIME_BACKGROUND_PID=$!
for (( _wait_attempt=0; _wait_attempt < 200; _wait_attempt++ )); do
    [ -e "$BLOCKED_HEAD_READY" ] && break
    sleep 0.05
done
assert_true "$([ -e "$BLOCKED_HEAD_READY" ] && echo 0 || echo 1)" \
    "the final hosted-head cancellation fixture starts its GitHub child"
BLOCKED_CHILD_PID=$(cat "$BLOCKED_HEAD_CHILD_PID" 2>/dev/null || echo "")
BLOCKED_DESCENDANT_PID=$(cat "$BLOCKED_HEAD_DESCENDANT_PID" 2>/dev/null || echo "")
kill -TERM "$RUNTIME_BACKGROUND_PID" 2>/dev/null || true
rc=0
wait "$RUNTIME_BACKGROUND_PID" || rc=$?
RUNTIME_BACKGROUND_PID=""
assert_eq "143" "$rc" \
    "TERM during the final hosted-head lookup preserves the conventional status"
assert_process_reaped "$BLOCKED_CHILD_PID" \
    "final hosted-head cancellation terminates the owned GitHub child"
assert_process_reaped "$BLOCKED_DESCENDANT_PID" \
    "final hosted-head cancellation terminates TERM-ignoring descendants"
assert_selection_views_match "$TERM_SELECTION_REPORT" "$FINAL_BOUNDARY_BACKUP" \
    "final hosted-head cancellation preserves every prior selected view"
assert_no_selection_transaction_residue "$TERM_SELECTION_REPORT" \
    "final hosted-head cancellation releases the writer lock"

# The public wrapper forwards INT as well as TERM to the selection transaction.
rm -f "$BLOCKED_HEAD_MARKER" "$BLOCKED_HEAD_READY" \
    "$BLOCKED_HEAD_CHILD_PID" "$BLOCKED_HEAD_DESCENDANT_PID"
INT_SELECTION_REPO="$TEST_OUTPUT_DIR/int-selection-workspace"
cp -R "$SELECTION_REPO" "$INT_SELECTION_REPO"
INT_SELECTION_REPORT="$INT_SELECTION_REPO/report"
set -m
(cd "$INT_SELECTION_REPO" && exec env PATH="$BLOCKED_HEAD_STUBS:$PATH" \
    UNAVAILABLE_HEAD_REPORT="$INT_SELECTION_REPORT" \
    UNAVAILABLE_HEAD_MARKER="$BLOCKED_HEAD_MARKER" \
    UNAVAILABLE_HEAD_REAL_CP="$(command -v cp)" \
    UNAVAILABLE_HEAD_BASE_GH="$STUB_DIR/gh" \
    BLOCKED_HEAD_READY="$BLOCKED_HEAD_READY" \
    BLOCKED_HEAD_CHILD_PID="$BLOCKED_HEAD_CHILD_PID" \
    BLOCKED_HEAD_DESCENDANT_PID="$BLOCKED_HEAD_DESCENDANT_PID" \
    "$GH_PR_ENRICH" select-analysis "$INT_SELECTION_REPORT" \
        "$INT_SELECTION_REPORT/hybrid-analysis.json") >/dev/null 2>&1 &
RUNTIME_BACKGROUND_PID=$!
set +m
for (( _wait_attempt=0; _wait_attempt < 200; _wait_attempt++ )); do
    [ -e "$BLOCKED_HEAD_READY" ] && break
    sleep 0.05
done
kill -INT "$RUNTIME_BACKGROUND_PID" 2>/dev/null || true
rc=0
wait "$RUNTIME_BACKGROUND_PID" || rc=$?
RUNTIME_BACKGROUND_PID=""
INT_BLOCKED_CHILD_PID=$(cat "$BLOCKED_HEAD_CHILD_PID" 2>/dev/null || echo "")
INT_BLOCKED_DESCENDANT_PID=$(cat \
    "$BLOCKED_HEAD_DESCENDANT_PID" 2>/dev/null || echo "")
assert_eq "130" "$rc" \
    "INT during the final hosted-head lookup preserves the conventional status"
assert_process_reaped "$INT_BLOCKED_CHILD_PID" \
    "INT cancellation reaps its direct GitHub child"
assert_process_reaped "$INT_BLOCKED_DESCENDANT_PID" \
    "INT cancellation reaps TERM-ignoring descendants"
assert_selection_views_match "$INT_SELECTION_REPORT" "$FINAL_BOUNDARY_BACKUP" \
    "INT cancellation preserves every prior selected view"
assert_no_selection_transaction_residue "$INT_SELECTION_REPORT" \
    "INT cancellation releases the writer lock"

# The same managed child has a portable deadline when no signal arrives.
TIMEOUT_SELECTION_REPO="$TEST_OUTPUT_DIR/timeout-selection-workspace"
cp -R "$SELECTION_REPO" "$TIMEOUT_SELECTION_REPO"
TIMEOUT_SELECTION_REPORT="$TIMEOUT_SELECTION_REPO/report"
rm -f "$BLOCKED_HEAD_MARKER" "$BLOCKED_HEAD_READY" \
    "$BLOCKED_HEAD_CHILD_PID" "$BLOCKED_HEAD_DESCENDANT_PID"
rc=0
BOUNDED_HEAD_OUT=$(cd "$TIMEOUT_SELECTION_REPO" && \
    env PATH="$BLOCKED_HEAD_STUBS:$PATH" \
    GH_PR_ENRICH_GITHUB_TIMEOUT=1 \
    UNAVAILABLE_HEAD_REPORT="$TIMEOUT_SELECTION_REPORT" \
    UNAVAILABLE_HEAD_MARKER="$BLOCKED_HEAD_MARKER" \
    UNAVAILABLE_HEAD_REAL_CP="$(command -v cp)" \
    UNAVAILABLE_HEAD_BASE_GH="$STUB_DIR/gh" \
    BLOCKED_HEAD_READY="$BLOCKED_HEAD_READY" \
    BLOCKED_HEAD_CHILD_PID="$BLOCKED_HEAD_CHILD_PID" \
    BLOCKED_HEAD_DESCENDANT_PID="$BLOCKED_HEAD_DESCENDANT_PID" \
    "$GH_PR_ENRICH" select-analysis "$TIMEOUT_SELECTION_REPORT" \
        "$TIMEOUT_SELECTION_REPORT/hybrid-analysis.json" 2>&1) || rc=$?
BOUNDED_CHILD_PID=$(cat "$BLOCKED_HEAD_CHILD_PID" 2>/dev/null || echo "")
BOUNDED_DESCENDANT_PID=$(cat \
    "$BLOCKED_HEAD_DESCENDANT_PID" 2>/dev/null || echo "")
assert_true "$([ "$rc" -ne 0 ] && [ -e "$BLOCKED_HEAD_READY" ] && echo 0 || echo 1)" \
    "the final hosted-head lookup enforces its managed timeout"
assert_process_reaped "$BOUNDED_CHILD_PID" \
    "the hosted-head timeout reaps its direct GitHub child"
assert_process_reaped "$BOUNDED_DESCENDANT_PID" \
    "the hosted-head timeout reaps TERM-ignoring descendants"
assert_contains "$BOUNDED_HEAD_OUT" "could not be revalidated during selection" \
    "the hosted-head timeout preserves the unavailable status"
assert_selection_views_match "$TIMEOUT_SELECTION_REPORT" "$FINAL_BOUNDARY_BACKUP" \
    "the hosted-head timeout preserves every prior selected view"
assert_no_selection_transaction_residue "$TIMEOUT_SELECTION_REPORT" \
    "the hosted-head timeout releases the writer lock"

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
assert_contains "$HOSTED_HEAD_OUT" "Hosted PR revision changed" \
    "the selection error identifies the hosted revision race"
assert_true "$([ ! -e "$AUTHORIZED_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "a hosted revision race invalidates the stale selected artifact"
assert_eq "do not overwrite" "$(cat "$TEST_OUTPUT_DIR/selection-temp-target.json")" \
    "selection invalidation never follows a planted fixed-name temp symlink"
rm "$AUTHORIZED_DIR/combined-data.tmp.json"
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$HYBRID_SOURCE" >/dev/null

rc=0
HOSTED_BASE_OUT=$(PR_BASE_OID="new-hosted-base" \
    "$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" \
        "$HYBRID_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects a result after a same-head base advance"
assert_contains "$HOSTED_BASE_OUT" "Hosted PR revision changed" \
    "the selection error identifies the hosted base race"
assert_true "$([ ! -e "$AUTHORIZED_DIR/analysis.json" ] && echo 0 || echo 1)" \
    "a hosted base race invalidates the stale selected artifact"
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$HYBRID_SOURCE" >/dev/null

MISSING_INTENT_DIR="$TEST_OUTPUT_DIR/missing-intent-context"
cp -R "$AUTHORIZED_DIR" "$MISSING_INTENT_DIR"
jq 'del(.coverage.intent.fingerprint, .coverage.context_fingerprint)' \
    "$MISSING_INTENT_DIR/analysis-context.json" \
    > "$MISSING_INTENT_DIR/analysis-context.tmp.json"
MISSING_INTENT_FINGERPRINT=$("$GH_PR_ENRICH" --test-call \
    analysis_context_fingerprint "$MISSING_INTENT_DIR/analysis-context.tmp.json")
jq --arg fingerprint "$MISSING_INTENT_FINGERPRINT" \
    '.coverage.context_fingerprint = $fingerprint' \
    "$MISSING_INTENT_DIR/analysis-context.tmp.json" \
    > "$MISSING_INTENT_DIR/analysis-context.json"
rm "$MISSING_INTENT_DIR/analysis-context.tmp.json"
jq --arg fingerprint "$MISSING_INTENT_FINGERPRINT" \
    '._metadata.context_fingerprint = $fingerprint' \
    "$MISSING_INTENT_DIR/hybrid-analysis.json" \
    > "$MISSING_INTENT_DIR/hybrid-analysis.tmp.json"
mv "$MISSING_INTENT_DIR/hybrid-analysis.tmp.json" \
    "$MISSING_INTENT_DIR/hybrid-analysis.json"
MISSING_INTENT_SELECTED_BEFORE=$(jq -c . "$MISSING_INTENT_DIR/analysis.json")
rc=0
MISSING_INTENT_OUT=$(validate_candidate_contract "$MISSING_INTENT_DIR" \
    "$MISSING_INTENT_DIR/hybrid-analysis.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "selection rejects completed hosted inputs without an intent fingerprint"
assert_contains "$MISSING_INTENT_OUT" "Required GitHub analysis inputs failed" \
    "missing intent identity fails at the required-input gate"
assert_eq "$MISSING_INTENT_SELECTED_BEFORE" \
    "$(jq -c . "$MISSING_INTENT_DIR/analysis.json")" \
    "missing intent identity preserves the prior selected result"

FORGED_IDENTITY_SOURCE="$AUTHORIZED_DIR/forged-identity-analysis.json"
jq '._metadata.repository = "attacker/shadow" | ._metadata.pr_number = 999' \
    "$HYBRID_SOURCE" > "$FORGED_IDENTITY_SOURCE"
rc=0
FORGED_IDENTITY_OUT=$(validate_candidate_contract "$AUTHORIZED_DIR" \
    "$FORGED_IDENTITY_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "candidate metadata cannot redirect hosted-head verification to another PR"
assert_contains "$FORGED_IDENTITY_OUT" "fingerprinted context" \
    "identity redirection is rejected against the captured context"

MISMATCH_SOURCE="$AUTHORIZED_DIR/mismatched-analysis.json"
jq '._metadata.pr_head_sha = "wrong-head"' "$HYBRID_SOURCE" > "$MISMATCH_SOURCE"
rc=0
MISMATCH_OUT=$(validate_candidate_contract "$AUTHORIZED_DIR" \
    "$MISMATCH_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects a result for a different PR head"
assert_contains "$MISMATCH_OUT" "PR revision" \
    "the selection error names the revision mismatch"

BASE_MISMATCH_SOURCE="$AUTHORIZED_DIR/base-mismatched-analysis.json"
jq '._metadata.pr_base_sha = "wrong-base"' "$HYBRID_SOURCE" \
    > "$BASE_MISMATCH_SOURCE"
rc=0
BASE_MISMATCH_OUT=$(validate_candidate_contract "$AUTHORIZED_DIR" \
    "$BASE_MISMATCH_SOURCE" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects a result for a different PR base"
assert_contains "$BASE_MISMATCH_OUT" "PR revision" \
    "the base provenance mismatch identifies the PR revision"

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

INVALID_ANCHOR_SOURCE="$AUTHORIZED_DIR/invalid-anchor-analysis.json"
jq '.issue_categories[0].evidence = [
        {file: "", line: 0, detail: "no usable anchor"}
    ]' "$HYBRID_SOURCE" > "$INVALID_ANCHOR_SOURCE"
rc=0
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$INVALID_ANCHOR_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects empty and zero-valued evidence anchors"

NEGATIVE_ANCHOR_SOURCE="$AUTHORIZED_DIR/negative-anchor-analysis.json"
jq '.issue_categories[0].evidence = [
        {file: "gh-pr-enrich", line: -1, detail: "invalid line"}
    ]' "$HYBRID_SOURCE" > "$NEGATIVE_ANCHOR_SOURCE"
rc=0
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$NEGATIVE_ANCHOR_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects negative evidence line anchors"

HIDDEN_ANCHOR_SOURCE="$AUTHORIZED_DIR/hidden-anchor-analysis.json"
jq '.issue_categories[0].evidence = [
        {file: "n/a", line: 1, detail: "renderer would hide this anchor"}
    ]' "$HYBRID_SOURCE" > "$HIDDEN_ANCHOR_SOURCE"
rc=0
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$HIDDEN_ANCHOR_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects the task-only n/a sentinel in finding evidence"

ZERO_REAL_TASK_LINE_SOURCE="$AUTHORIZED_DIR/zero-real-task-line-analysis.json"
jq '.task_list = [{
        priority: "high", task: "fixture task",
        finding_ids: [.issue_categories[0].finding_id], thread_ids: [],
        file: "gh-pr-enrich", line: 0, suggested_fix: "fixture",
        verification: "fixture"
    }]' "$HYBRID_SOURCE" > "$ZERO_REAL_TASK_LINE_SOURCE"
rc=0
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$ZERO_REAL_TASK_LINE_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects line zero for a real task file"
assert_eq "$SELECTED_BEFORE" "$(jq -c . "$AUTHORIZED_DIR/analysis.json")" \
    "invalid evidence anchors do not replace selected JSON"
assert_eq "$REPORT_BEFORE" "$(cat "$AUTHORIZED_DIR/analysis.md")" \
    "invalid evidence anchors do not replace selected Markdown"

UNATTRIBUTED_SOURCE="$AUTHORIZED_DIR/unattributed-hybrid.json"
jq '.issue_categories = [{
        finding_id: "unattributed", name: "Unattributed finding",
        category: "logic_error", severity: "high",
        impact: "moderate", likelihood: "likely", severity_rationale: "fixture",
        verdict: "confirmed", confidence: "high", description: "fixture",
        evidence: [{file: "gh-pr-enrich", line: 1, detail: "fixture"}], thread_ids: []
    }]' "$HYBRID_SOURCE" > "$UNATTRIBUTED_SOURCE"
rc=0
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$UNATTRIBUTED_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "hybrid findings require per-finding analyzer attribution"
assert_eq "$SELECTED_BEFORE" "$(jq -c . "$AUTHORIZED_DIR/analysis.json")" \
    "an unattributed hybrid finding does not replace selected JSON"

INVALID_PROVIDER_SOURCE="$AUTHORIZED_DIR/invalid-provider.json"
jq '._metadata.provider = "unknown-provider"' "$HYBRID_SOURCE" > "$INVALID_PROVIDER_SOURCE"
rc=0
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$INVALID_PROVIDER_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects unknown provider provenance"

NO_EVIDENCE_SOURCE="$AUTHORIZED_DIR/no-evidence.json"
jq '.issue_categories = [{
        finding_id: "no-anchor", name: "No anchor",
        category: "boundary_condition", severity: "high",
        impact: "moderate", likelihood: "likely", severity_rationale: "fixture",
        verdict: "confirmed", confidence: "high", description: "fixture",
        evidence: [], thread_ids: [], sources: ["codex:orchestrator"]
    }]
    | .category_coverage |= map(if .category == "boundary_condition"
        then .verdict = "findings_reported" else . end)' \
    "$HYBRID_SOURCE" > "$NO_EVIDENCE_SOURCE"
rc=0
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$NO_EVIDENCE_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects evidence-free findings"

CONTRADICTORY_SOURCE="$AUTHORIZED_DIR/contradictory-coverage.json"
jq '.issue_categories = [{
        finding_id: "anchored", name: "Anchored",
        category: "boundary_condition", severity: "high",
        impact: "moderate", likelihood: "likely", severity_rationale: "fixture",
        verdict: "confirmed", confidence: "high", description: "fixture",
        evidence: [{file:"a.js",line:1,detail:"fixture"}], thread_ids: [],
        sources: ["codex:orchestrator"]
    }]' "$HYBRID_SOURCE" > "$CONTRADICTORY_SOURCE"
rc=0
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$CONTRADICTORY_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "select-analysis rejects findings contradicted by reviewed-none coverage"

SWAPPED_ROLES_SOURCE="$AUTHORIZED_DIR/swapped-roles.json"
jq '._metadata.analyzers = [
        {provider:"codex",role:"external"},
        {provider:"claude",role:"orchestrator"}
    ]' "$HYBRID_SOURCE" > "$SWAPPED_ROLES_SOURCE"
rc=0
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$SWAPPED_ROLES_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "hybrid provenance rejects swapped orchestrator and external roles"

MISLABELED_CODEX_SOURCE="$AUTHORIZED_DIR/mislabeled-codex.json"
jq '._metadata.provider = "codex"
    | ._metadata.analyzers = [
        {provider:"codex",role:"orchestrator"},
        {provider:"claude",role:"external"}
    ]' "$HYBRID_SOURCE" > "$MISLABELED_CODEX_SOURCE"
rc=0
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$MISLABELED_CODEX_SOURCE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a Codex label cannot conceal an external Claude analyzer"

INVENTED_SOURCE_ID="$AUTHORIZED_DIR/invented-source-id.json"
jq '.issue_categories = [{
        finding_id: "invented-source", name: "Invented source",
        category: "boundary_condition", severity: "high",
        impact: "moderate", likelihood: "likely", severity_rationale: "fixture",
        verdict: "confirmed", confidence: "high", description: "fixture",
        evidence: [{file:"a.js",line:1,detail:"fixture"}], thread_ids: [],
        sources: ["codex:invented"]
    }]
    | .category_coverage |= map(if .category == "boundary_condition"
        then .verdict = "findings_reported" else . end)' \
    "$HYBRID_SOURCE" > "$INVENTED_SOURCE_ID"
rc=0
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$INVENTED_SOURCE_ID" >/dev/null 2>&1 || rc=$?
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
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$AUTHORIZED_DIR/source-failed-analysis.json" >/dev/null 2>&1 || rc=$?
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
validate_candidate_contract "$AUTHORIZED_DIR" \
    "$AUTHORIZED_DIR/missing-sources-analysis.json" >/dev/null 2>&1 || rc=$?
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
    rc=0
    TRUNCATION_OUT=$(validate_candidate_contract "$TRUNCATION_CASE_DIR" \
        "$TRUNCATION_CASE_DIR/candidate.json" 2>&1) || rc=$?
    assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
        "$TRUNCATION_CASE truncation rejects clean category verdicts"
    assert_contains "$TRUNCATION_OUT" "analysis inputs require" \
        "$TRUNCATION_CASE rejection identifies the incomplete-evidence contract"
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
NO_CODE_OR_DIFF_OUT=$(validate_candidate_contract "$NO_CODE_OR_DIFF_DIR" \
    "$NO_CODE_OR_DIFF_DIR/candidate.json" 2>&1) || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "clean category verdicts require either repository code access or an included diff"
assert_contains "$NO_CODE_OR_DIFF_OUT" "Incomplete or truncated analysis inputs" \
    "the no-code/no-diff rejection identifies the missing-evidence contract"
jq '.category_coverage |= map(.verdict = "not_reviewable")' \
    "$NO_CODE_OR_DIFF_DIR/candidate.json" \
    > "$NO_CODE_OR_DIFF_DIR/not-reviewable.json"
validate_candidate_contract "$NO_CODE_OR_DIFF_DIR" \
    "$NO_CODE_OR_DIFF_DIR/not-reviewable.json" >/dev/null
assert_jq "$NO_CODE_OR_DIFF_DIR/not-reviewable.json" \
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
PARTIAL_DIFF_OUT=$(validate_candidate_contract "$PARTIAL_DIFF_DIR" \
    "$PARTIAL_DIFF_DIR/candidate.json" 2>&1) || rc=$?
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
validate_candidate_contract "$TRUNCATION_POSITIVE_DIR" \
    "$TRUNCATION_POSITIVE_DIR/not-reviewable.json" >/dev/null
assert_jq "$TRUNCATION_POSITIVE_DIR/not-reviewable.json" \
    'all(.category_coverage[]; .verdict == "not_reviewable")' \
    "explicit not_reviewable coverage can be selected with truncated evidence"

jq '.issue_categories = [{
        finding_id:"visible-defect",name:"Visible defect",category:"logic_error",severity:"high",
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
validate_candidate_contract "$TRUNCATION_POSITIVE_DIR" \
    "$TRUNCATION_POSITIVE_DIR/mixed.json" >/dev/null
assert_jq "$TRUNCATION_POSITIVE_DIR/mixed.json" \
    '(.category_coverage[] | select(.category == "logic_error").verdict) == "findings_reported" and
     all(.category_coverage[]; .category == "logic_error" or .verdict == "not_reviewable")' \
    "findings remain selectable when every omitted clean axis is not_reviewable"

# A current Claude provider source is not a legacy fallback when selection has
# rejected or omitted analysis.json.
CURRENT_REJECTED_DIR="$TEST_OUTPUT_DIR/current-rejected"
mkdir -p "$CURRENT_REJECTED_DIR"
cp "$AUTHORIZED_DIR/analysis-context.json" "$CURRENT_REJECTED_DIR/analysis-context.json"
cp "$AUTHORIZED_CLAUDE_FIXTURE" "$CURRENT_REJECTED_DIR/claude-analysis.json"
rc=0
"$GH_PR_ENRICH" --test-call select_analysis_file "$CURRENT_REJECTED_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "a current rejected Claude source cannot bypass selection as a legacy fallback"

LEGACY_WITH_CONTEXT_DIR="$TEST_OUTPUT_DIR/legacy-with-current-context"
mkdir -p "$LEGACY_WITH_CONTEXT_DIR"
cp "$AUTHORIZED_DIR/analysis-context.json" "$LEGACY_WITH_CONTEXT_DIR/analysis-context.json"
jq 'del(._metadata)' "$AUTHORIZED_CLAUDE_FIXTURE" \
    > "$LEGACY_WITH_CONTEXT_DIR/claude-analysis.json"
rc=0
"$GH_PR_ENRICH" --test-call select_analysis_file "$LEGACY_WITH_CONTEXT_DIR" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "metadata-less legacy fallback is rejected beside a current analysis context"

LEGACY_READ_ONLY_DIR="$TEST_OUTPUT_DIR/legacy-read-only"
mkdir -p "$LEGACY_READ_ONLY_DIR"
jq 'del(._metadata)' "$AUTHORIZED_CLAUDE_FIXTURE" \
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
