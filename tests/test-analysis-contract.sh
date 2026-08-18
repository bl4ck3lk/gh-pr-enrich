#!/bin/bash
# Contract tests for the enrichment analysis: JSON schema, default prompt, and
# the Markdown renderer.
#
# The analysis is only as sharp as its contract. These tests pin the four
# properties that make findings verifiable rather than merely summarized:
#   1. every finding carries a verdict, confidence, and evidence
#   2. the category taxonomy is closed and every category gets an explicit verdict
#   3. severity is derived from impact x likelihood, not from the category
#   4. every task is anchored to a file/line with a fix and a verification step

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GH_PR_ENRICH="$PROJECT_DIR/gh-pr-enrich"
PROMPT_FILE="$PROJECT_DIR/default-prompt.txt"
TEST_OUTPUT_DIR="$SCRIPT_DIR/test-output/contract"

# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"

cleanup() { rm -rf "$TEST_OUTPUT_DIR"; }
trap cleanup EXIT
cleanup
mkdir -p "$TEST_OUTPUT_DIR"

suite_start "gh pr-enrich analysis contract suite"

SCHEMA_FILE="$TEST_OUTPUT_DIR/schema.json"
"$GH_PR_ENRICH" --test-call emit_analysis_schema > "$SCHEMA_FILE" 2>/dev/null || true

rc=0; jq -e . "$SCHEMA_FILE" > /dev/null 2>&1 || rc=$?
assert_true "$rc" "analysis schema is valid JSON"

PROMPT_TEXT=$(cat "$PROMPT_FILE")

# ---------------------------------------------------------------------------
# 1. Verification contract
# ---------------------------------------------------------------------------
IC='.properties.issue_categories.items'
assert_jq "$SCHEMA_FILE" "$IC.properties.verdict.enum | index(\"confirmed\") != null" \
    "finding carries a verdict enum including 'confirmed'"
assert_jq "$SCHEMA_FILE" "$IC.properties.verdict.enum | index(\"refuted\") != null" \
    "verdict enum can refute an incorrect review comment"
assert_jq "$SCHEMA_FILE" "$IC.properties.confidence.enum | length == 3" \
    "finding carries a confidence enum"
assert_jq "$SCHEMA_FILE" "$IC.properties.evidence.type == \"array\"" \
    "finding carries an evidence array"
assert_jq "$SCHEMA_FILE" "$IC.required | index(\"verdict\") != null and index(\"confidence\") != null and index(\"evidence\") != null" \
    "verdict, confidence and evidence are required on every finding"
assert_jq "$SCHEMA_FILE" '.properties.disputed_comments.type == "array"' \
    "schema has a disputed_comments section"
assert_jq "$SCHEMA_FILE" '.required | index("disputed_comments") != null' \
    "disputed_comments is required (silence is not a valid answer)"
assert_contains "$PROMPT_TEXT" "verify" "prompt instructs verification against the code"
assert_contains "$PROMPT_TEXT" "refuted" "prompt allows refuting a reviewer claim"

# ---------------------------------------------------------------------------
# 2. Closed taxonomy + forced coverage
# ---------------------------------------------------------------------------
assert_jq "$SCHEMA_FILE" "$IC.properties.category.enum | length >= 12" \
    "category taxonomy is a closed enum"
assert_jq "$SCHEMA_FILE" "$IC.required | index(\"category\") != null" \
    "category is required on every finding"
assert_jq "$SCHEMA_FILE" '.properties.category_coverage.type == "array"' \
    "schema has a category_coverage section"
assert_jq "$SCHEMA_FILE" '.required | index("category_coverage") != null' \
    "category_coverage is required"
assert_jq "$SCHEMA_FILE" '.properties.category_coverage.items.properties.verdict.enum | index("reviewed_none_found") != null' \
    "coverage verdict can record an explicit 'reviewed, none found'"

# Prompt and schema must not drift apart, in either direction. The prompt's own
# category list is the block of "- name: description" lines, so a category named
# only in a comment or in prose does not count as documented.
schema_cats=$(jq -r "$IC.properties.category.enum[]" "$SCHEMA_FILE" 2>/dev/null | sort)
# Only the closed category list counts — the prompt uses "- name: ..." bullets
# for other things (impact levels, input fields) that are not categories.
prompt_cats=$(awk '/^These are the categories/{inlist=1; next} inlist && /^## /{exit} inlist' "$PROMPT_FILE" \
    | grep -oE '^- [a-z_]+:' | sed 's/^- //; s/:$//' | sort -u)

missing_in_prompt=""
for cat in $schema_cats; do
    printf '%s\n' "$prompt_cats" | grep -qx "$cat" || missing_in_prompt="$missing_in_prompt $cat"
done
assert_eq "" "$missing_in_prompt" "every schema category is documented in the default prompt"

missing_in_schema=""
for cat in $prompt_cats; do
    printf '%s\n' "$schema_cats" | grep -qx "$cat" || missing_in_schema="$missing_in_schema $cat"
done
assert_eq "" "$missing_in_schema" "every prompt category exists in the schema enum"

assert_eq "$(printf '%s\n' "$schema_cats" | wc -l | tr -d ' ')" \
          "$(printf '%s\n' "$prompt_cats" | wc -l | tr -d ' ')" \
          "prompt and schema list the same number of categories"
assert_not_contains "$PROMPT_TEXT" "etc.)" "prompt category list is closed (no open-ended 'etc.')"

# ---------------------------------------------------------------------------
# 3. Severity decoupled from category
# ---------------------------------------------------------------------------
assert_jq "$SCHEMA_FILE" "$IC.properties.impact.enum | length >= 3" "finding carries an impact enum"
assert_jq "$SCHEMA_FILE" "$IC.properties.likelihood.enum | length >= 3" "finding carries a likelihood enum"
assert_jq "$SCHEMA_FILE" "$IC.required | index(\"impact\") != null and index(\"likelihood\") != null" \
    "impact and likelihood are required"
assert_jq "$SCHEMA_FILE" "$IC.required | index(\"severity_rationale\") != null" \
    "severity_rationale is required (severity must cite evidence)"
assert_contains "$PROMPT_TEXT" "impact" "prompt defines severity via impact"
assert_contains "$PROMPT_TEXT" "likelihood" "prompt defines severity via likelihood"
# The old prompt equated severity with category ("low: Style, documentation").
assert_not_contains "$PROMPT_TEXT" "low: Style, documentation" \
    "prompt no longer pins severity to a category"

# ---------------------------------------------------------------------------
# 4. Tasks anchored to code
# ---------------------------------------------------------------------------
TL='.properties.task_list.items'
for field in file line suggested_fix verification; do
    assert_jq "$SCHEMA_FILE" "$TL.properties.$field != null" "task carries '$field'"
    assert_jq "$SCHEMA_FILE" "$TL.required | index(\"$field\") != null" "task requires '$field'"
done

# ---------------------------------------------------------------------------
# 5. Renderer surfaces the new contract
# ---------------------------------------------------------------------------
ANALYSIS="$TEST_OUTPUT_DIR/analysis.json"
cat > "$ANALYSIS" << 'EOF'
{
  "issue_categories": [
    {
      "name": "Unchecked array index",
      "category": "boundary_condition",
      "severity": "critical",
      "impact": "severe",
      "likelihood": "likely",
      "severity_rationale": "Panics on empty input; reachable from the public parse() entry point.",
      "verdict": "confirmed",
      "confidence": "high",
      "description": "parse() indexes tokens[0] without a length check.",
      "evidence": [{"file": "src/parse.js", "line": 42, "detail": "tokens[0] read before length check"}],
      "thread_ids": ["PRRT_aaa"]
    }
  ],
  "disputed_comments": [
    {
      "thread_id": "PRRT_bbb",
      "claim": "This leaks memory",
      "why_incorrect": "The handle is closed by the defer on line 88.",
      "confidence": "high"
    }
  ],
  "category_coverage": [
    {"category": "concurrency", "verdict": "reviewed_none_found", "note": "No shared mutable state in the diff."},
    {"category": "boundary_condition", "verdict": "findings_reported", "note": "See parse() finding."}
  ],
  "systemic_issues": [],
  "adjacent_problems": [],
  "task_list": [
    {
      "priority": "critical",
      "task": "Guard tokens[0] with a length check",
      "thread_ids": ["PRRT_aaa"],
      "file": "src/parse.js",
      "line": 42,
      "suggested_fix": "if (tokens.length === 0) return null;",
      "verification": "npm test -- parse.test.js"
    }
  ],
  "process_improvements": [],
  "pr_template_suggestions": []
}
EOF

REPORT="$TEST_OUTPUT_DIR/analysis.md"
"$GH_PR_ENRICH" --test-call generate_analysis_report "$ANALYSIS" "$REPORT" 2>/dev/null
REPORT_TEXT=$(cat "$REPORT" 2>/dev/null || echo "")

assert_contains "$REPORT_TEXT" "confirmed" "report renders the finding verdict"
assert_contains "$REPORT_TEXT" "boundary_condition" "report renders the finding category"
assert_contains "$REPORT_TEXT" "src/parse.js:42" "report renders the evidence anchor"
assert_contains "$REPORT_TEXT" "severe" "report renders impact"
assert_contains "$REPORT_TEXT" "Disputed" "report renders the disputed-comments section"
assert_contains "$REPORT_TEXT" "The handle is closed by the defer on line 88." "report explains a refuted claim"
assert_contains "$REPORT_TEXT" "reviewed_none_found" "report renders category coverage"
assert_contains "$REPORT_TEXT" "npm test -- parse.test.js" "report renders the task verification step"

# A finding whose category is cosmetic can still be critical: severity must come
# from impact/likelihood, and the renderer must not re-derive it from category.
assert_contains "$REPORT_TEXT" "critical" "report renders severity independent of category"

# ---------------------------------------------------------------------------
# 6. The renderer must not die on a shape the model can still emit
#
# issue_categories[].evidence is objects; systemic_issues[].evidence is strings.
# A model that returns objects in both places used to abort the renderer with
# "string and object cannot be added" — after the expensive analysis was paid for.
# ---------------------------------------------------------------------------
ODD="$TEST_OUTPUT_DIR/odd-shapes.json"
cat > "$ODD" << 'EOF'
{
  "issue_categories": [],
  "disputed_comments": [],
  "category_coverage": [],
  "systemic_issues": [
    {
      "pattern": "Inconsistent error handling",
      "evidence": [
        {"file": "src/a.js", "line": 10, "detail": "empty catch"},
        "Thread PRRT_zzz: swallowed error"
      ],
      "recommendation": "Adopt one error wrapper."
    }
  ],
  "adjacent_problems": [],
  "task_list": [],
  "process_improvements": [],
  "pr_template_suggestions": []
}
EOF

ODD_REPORT="$TEST_OUTPUT_DIR/odd-shapes.md"
rc=0
"$GH_PR_ENRICH" --test-call generate_analysis_report "$ODD" "$ODD_REPORT" >/dev/null 2>&1 || rc=$?
assert_true "$rc" "renderer survives object-shaped systemic evidence"

ODD_TEXT=$(cat "$ODD_REPORT" 2>/dev/null || echo "")
assert_contains "$ODD_TEXT" "Inconsistent error handling" "the systemic pattern still renders"
assert_contains "$ODD_TEXT" "empty catch" "object-shaped evidence is rendered, not dropped"
assert_contains "$ODD_TEXT" "swallowed error" "string-shaped evidence still renders alongside it"

suite_end
