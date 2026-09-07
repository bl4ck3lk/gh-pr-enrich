#!/bin/bash
# Verify addresses against real Git blobs and captured working-tree bytes.
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GH_PR_ENRICH="${GH_PR_ENRICH_TEST_BINARY:-$PROJECT_DIR/gh-pr-enrich}"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output/evidence-anchors"
trap 'rm -rf "$TEST_OUTPUT_DIR"' EXIT
rm -rf "$TEST_OUTPUT_DIR"
mkdir -p "$TEST_OUTPUT_DIR/repo/report"
REPO="$TEST_OUTPUT_DIR/repo"
REPORT="$REPO/report"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git -C "$REPO" init -q
git -C "$REPO" config user.name Fixture
git -C "$REPO" config user.email fixture@example.invalid
printf 'report/\n' > "$REPO/.gitignore"
printf 'old first\nold second\n' > "$REPO/old.txt"
ln -s old.txt "$REPO/old-link"
git -C "$REPO" add .
git -C "$REPO" commit -qm base
BASE=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" mv old.txt renamed.txt
git -C "$REPO" rm -q old-link
printf 'one line\n' > "$REPO/tracked.txt"
printf 'no final newline' > "$REPO/tail.txt"
: > "$REPO/empty.txt"
printf 'unicode and newline path\n' > "$REPO/"$'résumé\nfile.txt'
git -C "$REPO" add .
git -C "$REPO" commit -qm head
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

capture_context() {
    local source="$1" workspace fingerprint
    workspace=$(cd "$REPO" && "$GH_PR_ENRICH" --test-call \
        code_access_workspace_fingerprint "$REPORT" "" "$source")
    jq -n --arg source "$source" --arg workspace "$workspace" \
        --arg head "$HEAD_SHA" --arg base "$BASE" '{
        pr:{number:1,repository:"o/r",head_sha:$head,base_sha:$base,base_ref_name:"main"},
        unresolved_threads:[],coverage:{code_access:{state:"enabled",
            snapshot_source:$source,pr_head_sha:$head,inspected_sha:$head,
            workspace_fingerprint:$workspace,revision_matches:true}}}' \
        > "$REPORT/analysis-context.json"
    fingerprint=$("$GH_PR_ENRICH" --test-call analysis_context_fingerprint \
        "$REPORT/analysis-context.json")
    jq --arg fingerprint "$fingerprint" '.coverage.context_fingerprint = $fingerprint' \
        "$REPORT/analysis-context.json" > "$TEST_OUTPUT_DIR/context.tmp"
    mv "$TEST_OUTPUT_DIR/context.tmp" "$REPORT/analysis-context.json"
    jq -n --arg workspace "$workspace" --arg fingerprint "$fingerprint" \
        --arg head "$HEAD_SHA" --arg base "$BASE" '{
        issue_categories:[{finding_id:"f1",verdict:"confirmed",thread_ids:[],
            evidence:[{file:"tracked.txt",line:1,detail:"fixture"}]}],task_list:[],
        _metadata:{repository:"o/r",pr_number:1,pr_head_sha:$head,
            pr_base_sha:$base,pr_base_ref_name:"main",context_fingerprint:$fingerprint,
            workspace_fingerprint:$workspace}}' > "$TEST_OUTPUT_DIR/source.json"
}

check_anchor() {
    local expected="$1" file="$2" line="$3" source="$4" description="$5" rc=0
    jq --arg file "$file" --argjson line "$line" --arg source "$source" \
        '.issue_categories[0].evidence[0] |= . + {file:$file,line:$line,source:$source}' \
        "$TEST_OUTPUT_DIR/source.json" > "$REPORT/codex-analysis.json"
    (cd "$REPO" && "$GH_PR_ENRICH" --test-call validate_selected_workspace \
        "$REPORT" "$REPORT/codex-analysis.json") > "$TEST_OUTPUT_DIR/result.log" 2>&1 || rc=$?
    if [ "$expected" = accepted ]; then
        assert_eq 0 "$rc" "$description"
    else
        assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "$description"
    fi
}

suite_start "gh pr-enrich evidence anchors suite"
capture_context git_index
check_anchor accepted tracked.txt 1 workspace 'a valid reviewed Git-blob address is accepted'
check_anchor rejected never-existed.txt 1 workspace 'nonexistent evidence files are rejected'
check_anchor rejected $'missing\033[31m.txt' 1 workspace 'control-bearing nonexistent evidence files are rejected'
diagnostic_escape_rc=0
LC_ALL=C grep -q $'\033' "$TEST_OUTPUT_DIR/result.log" || diagnostic_escape_rc=$?
assert_eq 1 "$diagnostic_escape_rc" 'invalid evidence paths cannot inject terminal escape bytes into diagnostics'
check_anchor rejected tracked.txt 1000000 workspace 'out-of-range evidence lines are rejected'
check_anchor rejected empty.txt 1 workspace 'an empty file has no line one'
check_anchor accepted tail.txt 1 workspace 'a final line without newline is addressable'
check_anchor accepted $'résumé\nfile.txt' 1 workspace 'Unicode and newline filenames resolve without splitting'
check_anchor rejected ../tracked.txt 1 workspace 'parent traversal is rejected'
check_anchor rejected "$REPO/tracked.txt" 1 workspace 'absolute paths are rejected'
check_anchor accepted renamed.txt 2 workspace 'renamed files resolve in the reviewed workspace'
check_anchor rejected old.txt 1 workspace 'deleted files cannot masquerade as workspace evidence'
check_anchor accepted old.txt 2 base 'deleted evidence resolves against the captured base commit'
check_anchor rejected renamed.txt 1 base 'base anchors cannot silently use head-side paths'
check_anchor rejected old-link 1 base 'base symlinks are not accepted as regular code evidence'
check_anchor rejected tracked.txt 1 unknown 'unknown evidence sources are rejected'

# A clean-filter/smudge workflow can expose more lines than the indexed blob.
printf 'one line\nlocal second line\n' > "$REPO/tracked.txt"
check_anchor rejected tracked.txt 2 workspace 'index evidence counts indexed bytes, not local file bytes'
capture_context working_tree
check_anchor accepted tracked.txt 2 workspace 'explicit working-tree evidence counts captured local bytes'
printf 'new uncaptured line\n' >> "$REPO/tracked.txt"
check_anchor rejected tracked.txt 2 workspace 'changed working-tree bytes invalidate evidence'
capture_context working_tree
check_anchor accepted tracked.txt 2 workspace 'recaptured working-tree evidence is usable'
jq '.task_list = [{finding_ids:["f1"],thread_ids:[],file:"tracked.txt",line:1000000}]' \
    "$REPORT/codex-analysis.json" > "$REPORT/hybrid-analysis.json"
rc=0
(cd "$REPO" && "$GH_PR_ENRICH" --test-call validate_selected_workspace \
    "$REPORT" "$REPORT/hybrid-analysis.json") >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" 'task locations must resolve as well as finding evidence'
suite_end
