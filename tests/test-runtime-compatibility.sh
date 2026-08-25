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

# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

cleanup() { rm -rf "$TEST_OUTPUT_DIR" "$TMP_ALIAS_OUTPUT"; }
trap cleanup EXIT
cleanup
mkdir -p "$STUB_DIR"

suite_start "gh pr-enrich runtime compatibility suite"

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
        *closingIssuesReferences*) echo '{"data":{"repository":{"pullRequest":{"closingIssuesReferences":{"nodes":[]}}}}}' ;;
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

SAST_PREPARED="$TEST_OUTPUT_DIR/sast-prepared"
env PATH="$STUB_DIR:$PATH" GH_PR_ENRICH_CODE_ACCESS=true \
    "$GH_PR_ENRICH" 1 --prepare-analysis --sast --output-dir "$SAST_PREPARED" >/dev/null 2>&1
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
    "$GH_PR_ENRICH" 1 --enrich --allow-external --output-dir "$AUTHORIZED_DIR" >/dev/null 2>&1

assert_true "$([ -s "$CLAUDE_LOG" ] && echo 0 || echo 1)" \
    "--allow-external authorizes Claude for a private repository"
assert_jq "$AUTHORIZED_DIR/analysis.json" '._metadata.repository_visibility == "PRIVATE"' \
    "the analysis provenance records repository visibility"

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
"$GH_PR_ENRICH" select-analysis "$AUTHORIZED_DIR" "$HYBRID_SOURCE" >/dev/null

assert_jq "$AUTHORIZED_DIR/analysis.json" '._metadata.provider == "hybrid"' \
    "select-analysis promotes a root-verified hybrid artifact"
assert_contains "$(cat "$AUTHORIZED_DIR/analysis.md")" "Hybrid-selected task" \
    "select-analysis regenerates the selected Markdown report"
assert_jq "$AUTHORIZED_DIR/combined-data.json" \
    '.analysis._metadata.provider == "hybrid" and .analysis.task_list[0].task == "Hybrid-selected task"' \
    "select-analysis refreshes the combined-data selected view"

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
