# PR Risk Profile — Design

**Date:** 2026-08-11
**Status:** Approved for planning
**Scope:** `gh-pr-enrich` — new `--risk` analysis axis

## Problem

`--enrich` analyzes PR *comments*: `build_claude_context()` sends unresolved review threads and
issue comments to Claude. The `--diff` flag adds code only as background for interpreting those
comments.

Nothing in the pipeline analyzes the *change itself*. A reviewer opening a PR gets no answer to:

- What does this change put at risk, and how far does it reach?
- Which hunks need a human, and what should that human check?
- Which parts are mechanical enough to hand to a coding agent?
- What should someone actually do in the running app to try to break it?

The risk profile is a change-driven analysis, not a bigger comment prompt. It is a separate
artifact with a separate schema and a separate invocation.

## Scope decisions

| Decision | Choice | Consequence |
|---|---|---|
| Ownership | `gh-pr-enrich` end-to-end | The profile exists before anyone opts into an expensive multi-agent audit. `xray` reads `risk-profile.json` rather than recomputing it. |
| Data source | Local git, read-only refs | Enables reference counts, defect density, author familiarity, CODEOWNERS. Never switches branches or writes to the working tree. |
| Risk rules | Claude classifies paths into a fixed taxonomy | No per-repo glob lists to maintain. The taxonomy and its weights stay in the script, so the score stays attributable. |

### What the model does and does not decide

Claude assigns each changed path to one class in a fixed taxonomy. It never assigns the score,
the tier, or the weights. Every numeric signal is computed by `git` and `jq`.

Classifications are cached per repository. Repeat runs classify only paths not already in the
cache, so the mapping is stable across PRs and auditable after the fact. Most runs on an
established repo make no classification call at all.

## Taxonomy and weights

Fixed in the script. Claude maps paths into it; it cannot invent classes.

| Class | Weight | Agent-safe eligible |
|---|---|---|
| `data_migration` | 18 | No |
| `authn_authz` | 18 | No |
| `payments_billing` | 18 | No |
| `pii_privacy` | 15 | No |
| `concurrency_state` | 12 | No |
| `public_api_contract` | 12 | Yes |
| `infra_ci_config` | 8 | Yes |
| `dependency_manifest` | 6 | Yes |
| `build_tooling` | 4 | Yes |
| `ui_presentation` | 2 | Yes |
| `other` | 1 | Yes |
| `test` | 0 | Yes |
| `docs` | 0 | Yes |

Classification resolution order, first match wins:

1. `.gh-pr-enrich-path-classes.json` at repo root (pin file — manual override)
2. `<reports_root>/path-classes.json` (cache)
3. Claude call A
4. `other`, with the path recorded in `signals_unavailable`

## Deterministic signals

All reads target `origin/<baseRefName>` via `git show`, `git grep`, and `git log`. No checkout,
no branch switch, no working-tree write. When a read fails, the affected signal name is appended
to `signals_unavailable[]` and its score contribution is zero — never silently treated as a
passing value.

### Per file

| Field | Derivation |
|---|---|
| `path`, `additions`, `deletions`, `status` | `pr-summary.json` |
| `is_test` | Path matches `(^\|/)(tests?\|__tests__\|spec)/`, `\.(test\|spec)\.[a-z]+$`, `_test\.(go\|py)$`, `Tests?\.swift$` |
| `class`, `class_source` | Taxonomy resolution above; source is `pin`, `cache`, `model`, or `fallback` |
| `references.count`, `references.sample[]` | `git grep -l -F` in the base ref for the path-without-extension and the basename-without-extension, excluding the file itself, lockfiles, and minified assets |
| `history.commits`, `history.fix_commits`, `history.defect_density` | `git log --format=%s` on the base ref for the path; `fix_commits` counts subjects matching `^(fix\|revert\|hotfix)` or `\b(bug\|regression)\b`, case-insensitive |
| `history.distinct_authors` | `git log --format=%ae \| sort -u \| wc -l` |
| `author_familiar` | PR author login matched case-insensitively against committer names and email local-parts in that file's history |
| `codeowners[]` | Glob match against `.github/CODEOWNERS`, `CODEOWNERS`, or `docs/CODEOWNERS` read via `git show` |

`references.count` is a **textual reference count**, not a resolved import graph. It counts files
that mention the module by name. The report labels it as such. A real import graph is a possible
later upgrade via the existing `dependency-graph` skill; this design does not claim one.

`author_familiar` is a heuristic — GitHub logins do not reliably map to git identities. When no
commit in a file's history matches any identity form, the signal is recorded as `unknown` and
contributes zero, rather than being reported as "author is new to this file".

### Repo level

`total_files`, `total_additions`, `total_deletions`, `test_line_ratio`, `max_file_delta`,
`base_ref`, `head_sha`, `signals_unavailable[]`.

### Diff-hunk scans

One function, `scan_diff_hunks()`, produces both lists from `pr-diff.txt`.

**Contract-break candidates** — removed lines (`^-`) matching:

- `export (default )?(async )?(function|class|const|let|var|type|interface|enum) NAME`
- `export { ... }` member lists
- Swift `(public|open) (func|var|let|class|struct|enum|protocol) NAME`
- Go exported `func [A-Z]...`
- Python module-level `def NAME` / `class NAME` at indent 0
- Environment reads: `process.env.NAME`, `os.environ["NAME"]`, `ENV["NAME"]`

A removed symbol is dropped from the list if the same identifier appears on an added line
anywhere in the diff — that is a move or rename within the PR, not a contract break.

Added lines matching destructive DDL (`DROP TABLE|DROP COLUMN|DROP INDEX|ALTER TABLE ... DROP`)
are also contract-break candidates.

**Swallowed-error candidates** — added lines (`^+`) matching empty `catch` blocks,
`except ...: pass`, `|| null|undefined|{}|[]`, `?? {}|[]|null`, and Go `_ = err`.

Both lists are labeled "candidates for review" in the report. They are pattern matches, not
confirmed defects, and the wording must not imply otherwise.

## Scoring

Score is the sum of eight capped contributions. Each emits a `{signal, points, reason, evidence}`
record into `score.breakdown[]`, so any total can be traced back to the inputs that produced it.

| # | Contribution | Rule | Cap |
|---|---|---|---|
| A | Change class | Each distinct class present among changed files adds its weight once | 45 |
| B | Reference reach | Max `references.count` over non-test files: 0–2→0, 3–9→4, 10–29→8, 30–99→14, 100+→20 | 20 |
| C | Test deficit | Added test lines ÷ added code lines: ≥0.5→0, 0.2–0.5→4, 0.05–0.2→8, <0.05 and ≥50 code lines→14, zero test lines and ≥200 code lines→18 | 18 |
| D | Defect density | Max density over files with ≥5 commits: <0.2→0, 0.2–0.4→5, ≥0.4→10 | 10 |
| E | Familiarity gap | Fraction of non-test files author has never touched: 0→0, ≤0.34→3, ≤0.67→6, >0.67→9 | 9 |
| F | Contract breaks | 6 per distinct candidate | 18 |
| G | Swallowed errors | 3 per added candidate | 9 |
| H | Churn | Total changed lines: <100→0, 100–399→3, 400–999→6, ≥1000→10 | 10 |

Empty-set rules, so no contribution divides by zero or scores an absent population as risky:

- **B** contributes 0 when the PR changes no non-test files.
- **C** contributes 0 when added code lines is 0 (a docs- or test-only PR is not a test deficit).
- **D** contributes 0 when no changed file has ≥5 commits of history.
- **E** counts only files whose `author_familiar` resolved to `true` or `false`. Files resolved as
  `unknown` are excluded from both numerator and denominator; when every file is `unknown`, E
  contributes 0 and `author_familiarity` is appended to `signals_unavailable[]`.

Tiers: `low` 0–14, `moderate` 15–34, `high` 35–64, `critical` ≥65.

These thresholds are an initial calibration. `retrospective` gains the data needed to tune them
later (see Future work); this design does not implement the tuning loop.

`score.completeness` is `full` when every signal resolved, `partial` otherwise. A `partial` score
is always rendered with the list of missing signals adjacent to it, so a low tier is never read as
an all-clear when the inputs were incomplete.

## Claude calls

Two calls with distinct schemas and one job each. When `--enrich` and `--risk` are both set, the
enrichment call and call B run concurrently (`&` then `wait`), so both flags cost one call's
latency rather than two.

### Call A — path classification

Input: the list of changed paths not resolved by pin file or cache.

```json
{
  "classifications": [
    { "path": "string", "class": "<taxonomy enum>", "rationale": "string, max 140 chars" }
  ]
}
```

Post-processing validates that every requested path came back exactly once with a class in the
enum. Missing or invalid entries fall back to `other` and are recorded in `signals_unavailable`.
Valid entries are merged into `<reports_root>/path-classes.json`.

Skipped entirely when the pin file and cache already cover every path.

### Call B — narrative

Input: PR title and body, `risk-signals.json`, resolved classes, both hunk-scan lists, and the
diff when `--diff` is set.

```json
{
  "impact_summary": "string",
  "human_focus":  [{ "file": "", "lines": "", "why": "", "what_to_check": "", "confidence": "high|medium|low" }],
  "agent_safe":   [{ "file": "", "scope": "", "justification": "", "guardrail": "" }],
  "manual_test_plan": [{ "step": 0, "action": "", "expected": "", "failure_mode": "", "covers": "" }],
  "post_merge_watch": [{ "signal": "", "where": "", "revert_hint": "" }]
}
```

`manual_test_plan` entries must be executable actions in the running application with a stated
expected result and the specific failure mode each step is designed to catch. Steps must cover
empty, error, and permission-denied states, not only the success path.

## Guardrails

**`agent_safe` deny-list is enforced in bash, after the model responds.** Any entry whose file
resolves to `data_migration`, `authn_authz`, `payments_billing`, `pii_privacy`, or
`concurrency_state` is dropped and logged to `risk-profile.json` under
`dropped_agent_safe_entries[]` with the reason. The model's judgment is not trusted for this.

**Failure is visible, never silent.** Every degraded path — unreachable base ref, missing
CODEOWNERS, unresolvable author identity, absent `claude` binary, malformed model output —
appends to `signals_unavailable[]` and is rendered in the report. There is no code path where a
missing signal is scored as if it had passed.

**No claim of precision the data does not support.** Reference counts are labeled textual, hunk
scans are labeled candidates, author familiarity is labeled heuristic.

## Output

### Files

| File | Location | Lifetime |
|---|---|---|
| `risk-signals.json` | PR output dir | Per PR |
| `risk-profile.json` | PR output dir | Per PR |
| `risk-profile.md` | PR output dir | Per PR |
| `path-classes.json` | Reports root — `$PR_REVIEW_OUTPUT_ROOT`, default `.reports/pr-reviews`, one level above the per-PR directory | Per repo, persistent cache |
| `.gh-pr-enrich-path-classes.json` | Repo root | Committed pin file, optional |

`risk-profile.json` is also merged into `combined-data.json` under `risk_profile`, matching how
`claude_analysis` is merged today.

### Report section

Appended to `comprehensive-report.md` and written standalone to `risk-profile.md`.

```
## 🎯 Risk Profile — HIGH (41)

Why: 2 data_migration files · 31 files reference src/sync/engine.ts ·
     0 test lines against 412 code lines · author new to 3 of 9 files

🔴 Human review required (3)   — file:lines, why it's subtle, what to check
🤖 Safe for a coding agent (4) — scope + justification + guardrail
🧪 Manual test plan (6 steps)  — action, expected, failure mode it catches
👀 After merge                 — what to watch, revert command

Signals unavailable: codeowners (no CODEOWNERS file found)
```

## CLI and pipeline integration

`--risk` is a new flag, independent of `--enrich`. Neither implies the other; they are different
analysis axes with different costs.

`fetch_pr_diff()` currently runs inside the `--enrich` branch. It moves out so `--risk` and
`--enrich` share one fetch instead of duplicating the network call when both are set.

When `claude` is unavailable or call B fails, the run still emits `risk-signals.json` and a
`risk-profile.md` containing the deterministic score, breakdown, and impact map. The narrative
sections are omitted and `score.completeness` is `partial`. A failed risk analysis never aborts
the rest of the report, matching the existing `--enrich` failure behavior.

## Refactor: remove the duplicated test hook

Lines 2472–2515 of `gh-pr-enrich` inline a second copy of `build_claude_context()` for the
`TEST_BUILD_CONTEXT_DIR` hook, with the comment "to avoid function scoping issues". The two
copies have already drifted apart in their diff handling, and the copy is exercised by the test
suite while the real function is not.

Adding three more functions under the same pattern would triple that debt. The root cause is
ordering: the main execution block runs before the function definitions are reached. Fix it by
moving all function definitions above the main block, then have the test hook call the real
function and delete the inlined copy.

`tests/test-enrichment-context.sh` must pass unchanged after this refactor — that is the proof
the duplicate was faithful and is now redundant.

## Testing

Written before implementation.

| Test | Covers |
|---|---|
| `tests/helpers/make-fixture-repo.sh` | Builds a scripted git repo in a temp dir with known history, authors, fix commits, and cross-file references |
| `tests/test-risk-signals.sh` | Asserts exact values for every deterministic signal against that fixture. No network, no `claude`. |
| `tests/test-risk-scoring.sh` | Feeds fixture signal sets to the scoring function and asserts score, tier, and full breakdown, including every cap boundary |
| `tests/test-risk-report.sh` | Renders fixture `risk-profile.json` to markdown; asserts the deny-list drops disallowed `agent_safe` entries and that `signals_unavailable` is always rendered |
| `tests/test-path-classes.sh` | Asserts resolution order (pin → cache → model → fallback), cache merge correctness, and that a fully-cached path set skips call A |

Test hooks follow the existing environment-variable pattern (`TEST_COMPUTE_SIGNALS_DIR`,
`TEST_SCORE_SIGNALS_FILE`, `TEST_RENDER_RISK_FILE`) but call the real functions rather than
inlined copies.

`.github/workflows/test.yml` gains a step per new test file.

## Documentation

**`SKILL.md`** gains a risk gate consistent with the existing thread-resolution and CI gates: when
the tier is `high` or `critical`, work may not be declared complete until the `manual_test_plan`
steps have been reported executed with their observed results. It also documents how to read
`risk-profile.json` and how to treat `agent_safe` as an allow-list for delegating work.

**`README.md`** gains the `--risk` flag, the new output files, the taxonomy table, the pin-file
format, and an explicit statement of what the signals do and do not mean.

## Non-goals

- No real import-graph resolution. Reference counts are textual.
- No coverage-data integration. Test deficit is measured in changed lines, not covered lines.
- No score calibration loop. `retrospective` integration is future work.
- No changes to `--enrich`, `watch`, `address`, or `resolve` behavior beyond the shared diff fetch
  and the function-ordering refactor.

## Future work

Record predicted tier against outcome — whether a PR was reverted or hotfixed within N days — and
feed that into `retrospective` to tune the thresholds in the scoring table against evidence rather
than intuition.
