#!/bin/bash
# Focused coverage for GitHub's 100-ID nodes() limit at the disclosure gate.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GH_PR_ENRICH="$PROJECT_DIR/gh-pr-enrich"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output/disclosure-batching"
STUB_DIR="$TEST_OUTPUT_DIR/stubs"

# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

cleanup() {
    rm -rf "$TEST_OUTPUT_DIR"
}
trap cleanup EXIT
cleanup
mkdir -p "$STUB_DIR"

cat > "$STUB_DIR/gh" <<'STUB'
#!/bin/bash
set -e

: > "$DISCLOSURE_ARGS_LOG"
: > "$DISCLOSURE_BATCH_ZERO"
: > "$DISCLOSURE_BATCH_ONE"
query=""
for argument in "$@"; do
    printf '%s\n' "$argument" >> "$DISCLOSURE_ARGS_LOG"
    case "$argument" in
        ids0[]=*)
            id=${argument#ids0[]=}
            jq -nc --arg id "$id" \
                '{id:$id,repository:{nameWithOwner:"intent/issues",visibility:"PUBLIC"}}' \
                >> "$DISCLOSURE_BATCH_ZERO"
            ;;
        ids1[]=*)
            id=${argument#ids1[]=}
            jq -nc --arg id "$id" \
                '{id:$id,repository:{nameWithOwner:"intent/issues",visibility:"PUBLIC"}}' \
                >> "$DISCLOSURE_BATCH_ONE"
            ;;
        query=*) query=${argument#query=} ;;
    esac
done
printf '%s\n' "$query" > "$DISCLOSURE_QUERY_LOG"

if [ "${DISCLOSURE_OMIT_SECOND_BATCH:-false}" = true ]; then
    jq -n --slurpfile zero "$DISCLOSURE_BATCH_ZERO" '{data:{
      primaryRepository:{id:"REPO_o_r",nameWithOwner:"o/r",visibility:"PUBLIC"},
      nodes:$zero
    }}'
else
    jq -n --slurpfile zero "$DISCLOSURE_BATCH_ZERO" \
        --slurpfile one "$DISCLOSURE_BATCH_ONE" '{data:{
          primaryRepository:{id:"REPO_o_r",nameWithOwner:"o/r",visibility:"PUBLIC"},
          nodes:$zero,linkedIssues1:$one
        }}'
fi
STUB
chmod +x "$STUB_DIR/gh"

CONTEXT_FILE="$TEST_OUTPUT_DIR/context.json"
jq -n '{pr:{repository:"o/r",repository_id:"REPO_o_r",linked_issues:[
  range(1;102) | {
    id:("ISSUE_" + tostring),
    repository:{name_with_owner:"intent/issues",visibility:"PUBLIC"}
  }
]}}' > "$CONTEXT_FILE"

ARGS_LOG="$TEST_OUTPUT_DIR/args.log"
QUERY_LOG="$TEST_OUTPUT_DIR/query.log"
BATCH_ZERO="$TEST_OUTPUT_DIR/batch-zero.jsonl"
BATCH_ONE="$TEST_OUTPUT_DIR/batch-one.jsonl"

suite_start "gh-pr-enrich disclosure batching suite"

env PATH="$STUB_DIR:$PATH" DISCLOSURE_ARGS_LOG="$ARGS_LOG" \
    DISCLOSURE_QUERY_LOG="$QUERY_LOG" DISCLOSURE_BATCH_ZERO="$BATCH_ZERO" \
    DISCLOSURE_BATCH_ONE="$BATCH_ONE" \
    "$GH_PR_ENRICH" --test-call verify_external_disclosure_sources \
        PUBLIC false < "$CONTEXT_FILE"
assert_eq "100" "$(wc -l < "$BATCH_ZERO" | tr -d ' ')" \
    "the first GraphQL nodes field is capped at 100 linked issues"
assert_eq "1" "$(wc -l < "$BATCH_ONE" | tr -d ' ')" \
    "the 101st linked issue is placed in a second nodes field"
assert_contains "$(cat "$QUERY_LOG")" 'linkedIssues1: nodes(ids: $ids1)' \
    "all visibility batches remain in one hosted GraphQL snapshot"

rc=0
env PATH="$STUB_DIR:$PATH" DISCLOSURE_ARGS_LOG="$ARGS_LOG" \
    DISCLOSURE_QUERY_LOG="$QUERY_LOG" DISCLOSURE_BATCH_ZERO="$BATCH_ZERO" \
    DISCLOSURE_BATCH_ONE="$BATCH_ONE" DISCLOSURE_OMIT_SECOND_BATCH=true \
    "$GH_PR_ENRICH" --test-call verify_external_disclosure_sources \
        PUBLIC false < "$CONTEXT_FILE" >/dev/null 2>&1 || rc=$?
assert_true "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" \
    "an incomplete linked-issue visibility batch fails closed"

suite_end
