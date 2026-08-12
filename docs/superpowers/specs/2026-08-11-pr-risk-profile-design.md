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
| Ownership | `gh-pr-enrich` producer; `xray` consumer | This repository owns the profile and v1 fixture. The separately released xray skill owns consumption and never recomputes it. |
| Data source | Exact Git base/head snapshot plus paginated PR-file and PR-commit metadata | Enables reference counts, defect density, verified author familiarity, and CODEOWNERS while preserving a repeatable PR snapshot. Git reads never switch branches or write to the working tree. |
| Risk rules | Optional Claude phase classifies changes into a fixed taxonomy | No per-repo glob lists to maintain. The taxonomy and its weights stay in the script, so the score stays attributable. |
| Remote analysis | Explicit, bounded opt-in | `--risk` alone is deterministic. Claude receives PR data only when the operator also opts into the approved remote-analysis path for that repository. |

### What the model does and does not decide

Claude assigns each changed path one or more supported classes only when bounded semantic evidence
from its diff or declaration context supports the assignment. It never assigns the score, the
tier, or the weights. Every numeric signal is computed by `git` and `jq`.

Classification is an evidence-backed fact, not a path-name guess. A path without enough evidence
is `unclassified`; it is never silently treated as `other` or safe to delegate. A classification
may contain multiple classes, and all of them participate in the score and safety checks.

Classifications are cached per repository. A cache entry is keyed by repository identity,
taxonomy version, canonical current path, base path, and fingerprints of the base-side blob at the
merge base, the complete per-file diff from the merge base to head, and the bounded semantic
evidence used to classify it. It also records the exact base, head, and merge-base OIDs as
provenance. The complete per-file diff fingerprint, rather
than the bounded evidence alone, invalidates the entry when any part of that file's change changes.
A missing or incomplete per-file diff disables cache reuse. A cache hit requires every keyed value
to match; otherwise the path is classified again. Cache updates are protected by a
repository-scoped lock and written by atomic rename, so concurrent runs cannot corrupt or mix
repository state.

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
| `unclassified` | 18 | No |
| `other` | 1 | No |
| `test` | 0 | Yes |
| `docs` | 0 | Yes |

Classification inputs and resolution:

1. `.gh-pr-enrich-path-classes.json` at repo root contributes base classifications only when read
   with `git show <base_oid>:.gh-pr-enrich-path-classes.json`.
2. The per-repository classification cache — `path-classes.json` at its canonical location
   defined once in the Output files table — supplies a provenance-checked current-change
   classification when its evidence fingerprint matches.
3. Claude call A classifies any remaining current changes from bounded semantic evidence.
4. A path without a current-change classification receives `unclassified`, with the reason
   recorded in `signals_unavailable[]`.

Effective `classes[]` is the union of a trusted base pin and the current-change classification;
a pin can add risk but cannot suppress new risk in the diff. A pin alone never qualifies a path
for `agent_safe`. It declares one or more taxonomy classes and a short human-reviewed reason, is
trusted only when it exists in the exact base commit and has already entered that base through the
repository's normal protected-branch and review controls, and cannot be changed by the PR it
classifies.

## Deterministic signals

The collection snapshot is `{base_oid, head_oid}` from `pr-summary.json.baseRefOid` and
`headRefOid`. Before and after every GitHub PR-file, PR-commit, or diff retrieval, the run re-reads
those values for the same PR. If either value changes, it discards the collected PR-file,
PR-commit, and diff payloads, records `pr_snapshot_changed`, and emits a partial profile rather
than mixing snapshots.

The diff is always merge-base derived. When the local base and head objects are available, the
run computes `merge_base_oid` with `git merge-base base_oid head_oid` and generates the diff with
`git diff base_oid...head_oid` (three-dot: merge base to head), so commits that landed only on an
advancing base branch never appear as spurious reverse changes. `merge_base_oid` is recorded in
`risk-signals.json` as provenance alongside the snapshot OIDs. When the merge base cannot be
computed locally, a provider diff is accepted only when both snapshot checks match — GitHub's PR
diff and pull-files endpoints already use merge-base semantics, so both sources describe the same
change, and the changed-file count assertion below stays coherent across sources. Every
diff-derived input — per-file diffs and `git diff --numstat` reads, `pr-diff.txt` and its hunk
scans, cache fingerprints, pre-send secret scanning, and model-facing diff excerpts — uses this
merge-base diff; no signal compares the `base_oid` and `head_oid` trees directly.

For base-derived reads, the run verifies that `origin/<baseRefName>` resolves to `base_oid`, then
uses the immutable `base_oid` in every `git show`, `git grep`, and `git log` call. No checkout,
branch switch, or working-tree write is allowed. A missing or mismatched ref is not fetched or
substituted: every affected signal is recorded as unavailable and contributes zero. These
base-derived signals (references, history, CODEOWNERS, pins) intentionally read the base branch
tip: they measure the state of the branch the PR merges into, while the change itself is always
taken from the merge-base diff defined above.

Changed-file metadata comes from the paginated GitHub pull-files endpoint. It is normalized into
`path`, `base_path`, `additions`, `deletions`, and `status`: `path` is the current filename used in
reports, while `base_path` is `previous_filename` for a rename, `path` for a modified or removed
file, and `null` for an added file. Every base-derived blob, history, and reference read uses
`base_path`; head-derived evidence, CODEOWNERS matching, and report locations use `path`. The
CODEOWNERS rules themselves still come from `base_oid`. The run asserts that its unique-file count
matches `pr-summary.json.changedFiles`. A pagination, normalization, or count mismatch records
`changed_files_incomplete`, makes the profile partial, and prevents the input from being presented
as a complete risk view.

### Per file

| Field | Derivation |
|---|---|
| `path`, `base_path`, `additions`, `deletions`, `status` | Paginated pull-files response, including `previous_filename` normalization for renames, count-checked against `pr-summary.json` |
| `is_test` | Path matches `(^\|/)(tests?\|__tests__\|spec)/`, `\.(test\|spec)\.[a-z]+$`, `_test\.(go\|py)$`, `Tests?\.swift$` |
| `is_test_source` | `is_test` and a UTF-8 text file with a source extension from the `is_code` allow-list, excluding paths matching `(^\|/)(fixtures?\|__fixtures__\|snapshots?\|__snapshots__\|docs?\|documentation)(/\|$)`, minified assets, files whose first 20 lines contain `@generated` or `DO NOT EDIT`, and files reported binary by `git diff --numstat` |
| `is_code` | Fixed, versioned predicate independent of Claude: a UTF-8 text file with extension in `c, cc, cpp, cs, go, java, js, jsx, mjs, cjs, ts, tsx, py, rb, php, rs, swift, kt, kts, scala, sh, sql`, excluding `is_test`, `(^\|/)(docs?\|documentation)/`, `(^\|/)generated/`, `*.min.js`, files whose first 20 lines contain `@generated` or `DO NOT EDIT`, and files reported binary by `git diff --numstat` |
| `classes[]`, `class_sources[]`, `classification_evidence[]` | Taxonomy resolution above; sources are `pin`, `cache`, `model`, or `unclassified` |
| `references.count`, `references.sample[]` | `git grep -l -F` at `base_oid` for the path-without-extension and the basename-without-extension, excluding the file itself, lockfiles, and minified assets |
| `history.commits`, `history.fix_commits`, `history.defect_density` | `git log --format=%s` at `base_oid` for the path; `fix_commits` counts subjects matching `^(fix\|revert\|hotfix)\b` or `\b(bug\|regression)\b`, case-insensitive |
| `history.distinct_authors` | `git log --format=%ae \| sort -u \| wc -l` |
| `author_familiar` | Verified PR-author email identities matched against author and committer emails in the file's base history |
| `codeowners[]` | Glob match against `.github/CODEOWNERS`, `CODEOWNERS`, or `docs/CODEOWNERS` read via `git show` |

`references.count` is a **textual reference count**, not a resolved import graph. It counts files
that mention the module by name. The report labels it as such. A real import graph is a possible
later upgrade via the existing `dependency-graph` skill; this design does not claim one.

`author_familiar` is a heuristic, but its three states are reachable without treating a login or
display name as a git identity. The runner builds an in-memory identity set from paginated PR
commit metadata: it accepts a normalized author or committer email only when GitHub resolves that
commit identity to the PR author's login. Raw identity values are not written to the profile. For a
file with base history, an exact email match produces `true` and a verified identity set with no
match produces `false`. No verified identity set, no base history, or unavailable commit/history
metadata produces `unknown` and contributes zero.

Added code lines and added test lines are sums over `is_code` and `is_test_source` files
respectively. Test-directory fixtures, snapshots, documentation, generated output, and other
non-source assets never enter the test-line numerator. An unrecognized textual file type that is
not one of the explicit exclusions is excluded from contribution C and recorded as
`test_deficit_file_type_unknown`; the score is partial rather than assuming it needs no tests.
This makes docs-only, manifest-only, configuration-only, lockfile-only, generated, and binary
changes zero-code inputs while keeping mixed source/test PRs deterministic.

For a file with at least five commits, `history.defect_density = history.fix_commits /
history.commits`, as a decimal in `[0, 1]`. A file with fewer than five commits has no density;
it is excluded from contribution D rather than assigned a synthetic zero.

### Repo level

`total_files`, `total_additions`, `total_deletions`, `test_line_ratio`, `max_file_delta`,
`base_ref`, `base_oid`, `head_oid`/`head_sha`, resolved `origin_base_oid`, source-file counts, and
`signals_unavailable[]`.

### Diff-hunk scans

One function, `scan_diff_hunks()`, produces both lists from `pr-diff.txt`.

**Contract-break candidates** — removed lines (`^-`) matching:

- `export (default )?(async )?(function|class|const|let|var|type|interface|enum) NAME`
- `export { ... }` member lists
- Swift `(public|open) (func|var|let|class|struct|enum|protocol) NAME`
- Go exported `func [A-Z]...`
- Python module-level `def NAME` / `class NAME` at indent 0
- Environment reads: `process.env.NAME`, `os.environ["NAME"]`, `ENV["NAME"]`

A same-named added identifier remains a candidate by default. It is marked as a probable
move/rename only when local comparison also matches declaration kind, exported visibility,
namespace or path, and normalized signature. That marker lowers confidence in the report; it does
not erase the candidate.

Added lines matching destructive DDL (`DROP TABLE|DROP COLUMN|DROP INDEX|ALTER TABLE ... DROP`)
are also contract-break candidates and append `destructive_ddl` to `validation_required[]`.

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
| C | Test deficit | Evaluate in order: zero test lines and ≥200 code lines→18; otherwise added test lines ÷ added code lines: ≥0.5→0, ≥0.2 and <0.5→4, ≥0.05 and <0.2→8, <0.05 and ≥50 code lines→14, <0.05 and 1–49 code lines→8 | 18 |
| D | Defect density | Max `history.fix_commits / history.commits` over files with ≥5 commits: <0.2→0, ≥0.2 and <0.4→5, ≥0.4→10 | 10 |
| E | Familiarity gap | Fraction of non-test files author has never touched: 0→0, >0 and ≤0.34→3, >0.34 and ≤0.67→6, >0.67→9 | 9 |
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

Coverage check: every contribution's ranges are disjoint and jointly cover its full input space.
B, D, E, and H partition their domains with no overlap and no gap; C, evaluated in order after its
empty-set rule, assigns exactly one value to every combination of added code lines (≥1) and test
ratio, including the sub-0.05-ratio bands at both 1–49 and ≥50 code lines. All contributions are
integers, the maximum total is 139, and the tier ranges below cover every integer from 0 to 139.
Any future edit to this table must preserve this property.

Tiers: `low` 0–14, `moderate` 15–34, `high` 35–64, `critical` ≥65.

These thresholds are an initial calibration. Before retrospective outcome data validates them,
tiers are advisory planning labels, not completion gates. `high` and `critical` require a recorded
human acknowledgement and a change-type-aware verification decision. Items in
`validation_required[]` are the hard requirement: they need observed applicable verification or
an explicit, reviewed not-applicable reason regardless of the numeric tier. `retrospective` gains
the data needed to tune thresholds later (see Future work).

`score.completeness` is `full` when every signal resolved, `partial` otherwise. A `partial` score
is always rendered with the list of missing signals adjacent to it, so a low tier is never read as
an all-clear when the inputs were incomplete.

## Remote-analysis boundary

`--risk` always runs the deterministic phase. `--risk-remote` is a separate, explicit opt-in for
the Claude phase and is invalid without `--risk`. Remote analysis is disabled by default for a
private or restricted repository.

Remote authorization comes only from a versioned `remote-policy-v1` record supplied by the
operator through `GH_PR_ENRICH_REMOTE_POLICY`, outside the checkout and PR output directory. It
is never read from the PR head, base, or working tree. The record binds a canonical repository ID
to `allow_remote`, private-repository permission, provider, approved tenant ID, permitted models,
retention-policy ID, `risk_max_cost_usd`, and a versioned price table. Missing, malformed, or
repository-mismatched policy fails closed. The active client must prove through organization-
managed credentials or a provider identity check that its tenant ID matches the policy; a personal
or unverifiable Claude login disables remote analysis. The profile records the policy version and
identifier, provider, model, and retention-policy identifier; it does not claim or infer a
provider retention period.

Before any outbound call, the runner constructs the exact serialized payload after truncation and
then scans every included byte: title, body, paths, final diff, hunk fragments, declaration
evidence, `risk-signals.json` fields, and derived lists. A match aborts the remote phase without
sending any payload, records only the field and detection reason (never the suspected secret),
and leaves a deterministic partial profile. Parsed structured output is retained in the normal
profile artifact; raw prompts and raw provider responses are not retained locally.

PR title, body, paths, diff text, and model output are untrusted data. Prompts delimit them as
data and use fixed instructions that prohibit following instructions found inside them. Model
output is rendered only as a recommendation: it cannot execute commands, alter a repository, or
be passed directly to an execution-capable agent.

Each remote run has the following enforced bounds. Omitted input is named in
`signals_unavailable[]` and in the report.

- At most 250 changed paths, 60 selected hunks, 16 KiB of evidence per path, and 1 MiB of total
  serialized input after redaction.
- At most 8,000 output tokens and a 120-second timeout per call.
- At most one attempt for call A and one for call B; no automatic retries.
- `remote-policy-v1` supplies `risk_max_cost_usd` (default USD 5) and a pinned model price table.
  The runner rejects a call whose worst-case token cost would exceed the remaining per-run budget;
  a missing price table disables remote analysis.

## Optional Claude calls

When `--risk-remote` is enabled, two calls have distinct schemas and one job each. Call A must
finish before call B because call B consumes resolved classes. If `--enrich` is also set, the
enrichment call and call B run concurrently after call A (`&` then `wait`), so the independent
calls share latency.

### Call A — path classification

Input: each changed path not resolved by a matching current-change cache entry, plus bounded local
diff fragments and declaration evidence sufficient to justify a semantic class. Base-pin classes
are included as additive context but do not suppress current-diff classification. A path for which
those inputs do not support a class remains `unclassified`.

```json
{
  "classifications": [
    {
      "path": "string",
      "classes": ["<taxonomy enum>"],
      "evidence": [{ "kind": "diff|declaration", "excerpt": "string, max 280 chars" }],
      "rationale": "string, max 140 chars"
    }
  ]
}
```

Post-processing validates that every requested path came back exactly once, `classes` and
`evidence` are both nonempty, every class is in the enum, and every returned evidence excerpt is
nonempty and corresponds to the bounded local input. Missing, empty, or invalid entries become
`unclassified` and are recorded in `signals_unavailable[]`. Only valid entries are merged into
the per-repository classification cache (canonical location in the Output files table) through
the locked, atomic update path.

Skipped entirely only when matching current-change cache entries cover every path; pin coverage
alone never skips call A.

### Call B — narrative

Input: bounded, approved PR title and body, `risk-signals.json`, resolved classes, both
hunk-scan lists, and the diff when `--diff` is set. It uses the same redaction, source, and
budget rules as call A.

```json
{
  "impact_summary": "string",
  "human_focus":  [{ "file": "", "lines": "", "why": "", "what_to_check": "", "confidence": "high|medium|low" }],
  "agent_safe":   [{ "file": "", "scope": "", "justification": "", "guardrail": "" }],
  "manual_test_plan": [{ "step": 0, "verification_type": "application|api|migration|build_ci|configuration|documentation", "action": "", "expected": "", "failure_mode": "", "covers": "", "applicability": "" }],
  "post_merge_watch": [{ "signal": "", "where": "", "rollback_condition": "" }]
}
```

`manual_test_plan` is change-type-aware. Application changes use executable actions in the running
application; API changes use a real endpoint or client; migrations use a disposable database or
staging-equivalent; build, CI, configuration, and documentation changes use their applicable
build, deploy, or review verification. Each step states its expected result and failure mode.
Empty, error, and permission-denied states are required only when application, API, or
authorization behavior makes them applicable. A pure documentation or build-only change can
record a reviewed `not_applicable` application check with its reason instead of inventing a UI
test.

`action` uses a fixed, type-specific declarative template: an application route/control, API
operation and fields, migration identifier, repository-declared check identifier, configuration
key, or documentation section. It rejects shell syntax, arbitrary commands or external URLs,
secret values, and free-form rollback instructions.

## Guardrails

**`agent_safe` is a constrained allow-list, enforced after the model responds.** An entry is
dropped unless its file is exactly one of the normalized changed paths, it has a nonempty,
validated current-change semantic classification with evidence (a pin alone is insufficient),
every class is agent-safe eligible, and no class is `other` or `unclassified`. Any entry resolving
to `data_migration`, `authn_authz`, `payments_billing`, `pii_privacy`, or `concurrency_state` is
dropped regardless of the model's judgment. Every dropped entry and reason is logged under
`dropped_agent_safe_entries[]`.

**Model output is declarative and untrusted.** Schema validation rejects extra executable fields.
`agent_safe` scopes, manual-test actions, post-merge watches, and rollback conditions are
human-reviewed text only; no shell command, repository mutation, or downstream autonomous action
is derived from them.

**Failure is visible, never silent.** Every degraded path — unreachable base ref, missing
CODEOWNERS, incomplete changed files, unresolvable author identity, rejected remote input, absent
`claude` binary, exhausted budget, timeout, or malformed model output — appends to
`signals_unavailable[]` and is rendered in the report. There is no code path where a missing
signal is scored as if it had passed.

**No claim of precision the data does not support.** Reference counts are labeled textual, hunk
scans are labeled candidates, author familiarity is labeled heuristic.

## Output

### Files

| File | Location | Lifetime |
|---|---|---|
| `risk-signals.json` | PR output dir | Per PR |
| `risk-profile.json` | PR output dir | Per PR |
| `risk-profile.md` | PR output dir | Per PR |
| `path-classes.json` | `<reports_root>/repos/<encoded-repository-id>/path-classes.json`; reports root defaults to `.reports/pr-reviews` | Per-repository persistent cache; identity, taxonomy version, base provenance, and evidence fingerprints are stored in every entry |
| `.gh-pr-enrich-path-classes.json` | Repo root | Committed pin file, optional |

`risk-profile.json` is also merged into `combined-data.json` under `risk_profile`, matching how
`claude_analysis` is merged today.

### Schema and `xray` contract

All risk artifacts declare `schema_version: 1`. `risk-signals.json` records repository identity,
PR number, the immutable `{base_oid, head_oid}` collection snapshot, resolved base OID, the
computed `merge_base_oid` (or its unavailability), changed-file source/count, normalized
current/base paths, signal availability, classes and their
provenance. `risk-profile.json` adds the score, tier, `validation_required[]`, narrative
availability, remote-analysis metadata, and any dropped agent-safe entries.

The `gh-pr-enrich` repository owns the v1 producer and the shared fixture at
`tests/fixtures/risk-profile-v1.json`. The consumer is a separately released `xray` skill change
owned by the canonical `~/.claude/skills/xray` package (mirrored to
`~/.codex/skills/xray`), with its consumer test at
`tests/unit-risk-profile-contract.sh`. Release order is producer first, then the xray consumer:
until the consumer change ships, xray reports the profile as unavailable rather than claiming to
consume it. The producer and fixture are in this repository's implementation scope; the xray
consumer is an explicit follow-up release dependency.

After that release, `xray` consumes only a schema-versioned profile found in the exact PR output
directory supplied by the invoking `gh-pr-enrich` run. It verifies repository identity, PR number,
and both snapshot OIDs before using `score`, `tier`, `completeness`,
`signals_unavailable[]`, `validation_required[]`, and `human_focus`. A missing, stale, or
schema-incompatible profile yields an explicit "risk profile unavailable" state and no
recomputation. A partial profile may be displayed with its missing signals, but it cannot
authorize delegation from `agent_safe`. The shared fixture runs in both producer and consumer
tests so schema drift fails before release.

### Report section

Appended to `comprehensive-report.md` and written standalone to `risk-profile.md`.

```
## 🎯 Risk Profile — HIGH (41)

Why: 2 data_migration files · 31 files reference src/sync/engine.ts ·
     0 test lines against 412 code lines · author new to 3 of 9 files

🔴 Human review required (3)   — file:lines, why it's subtle, what to check
🤖 Safe for a coding agent (4) — scope + justification + guardrail
🧪 Verification plan (6 steps) — type, action, expected, failure mode it catches
👀 After merge                 — what to watch, rollback condition

Signals unavailable: codeowners (no CODEOWNERS file found)
```

## CLI and pipeline integration

`--risk` is a new flag, independent of `--enrich`. Neither implies the other; they are different
analysis axes with different costs. `--risk-remote` is valid only with `--risk` and enables the
separately authorized remote phase; `--risk` by itself has no model egress.

`fetch_pr_diff()` currently runs inside the `--enrich` branch. It moves to the shared
precondition selected by `--risk` or an enrichment run that needs a diff, so both axes share one
fetch instead of duplicating the network call.

Remote calls may run concurrently only while they are independent: call A completes before call
B, then call B may run alongside `--enrich`. Workers return validated raw results to the
coordinator but never write `combined-data.json`, `comprehensive-report.md`, or final risk
artifacts. After all selected work finishes, one coordinator serially validates results, writes
risk artifacts through temporary files and atomic rename, merges `combined-data.json` once, and
appends report sections in a fixed order. This makes `--enrich --risk` race-free.

When remote analysis is not opted in, is forbidden by repository policy, is rejected by the
pre-send scanner, or `claude` is unavailable or fails, the run still emits `risk-signals.json` and
a `risk-profile.md` containing the deterministic score, breakdown, impact map, and the explicit
unavailable reason. Unresolved classifications remain `unclassified`, narrative sections are
omitted, and `score.completeness` is `partial`. A failed risk analysis never aborts the rest of
the report, matching the existing `--enrich` failure behavior.

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
| `tests/helpers/make-fixture-repo.sh` | Builds a scripted git repo in a temp dir with known history, authors, fix commits, cross-file references, semantic diff evidence, and more than 100 changed-file records |
| `tests/test-risk-input.sh` | Mocks paginated pull-file and pull-commit responses, normalizes status and rename `base_path` values, checks the file count against `changedFiles`, asserts the local diff is generated from the merge base (`base_oid...head_oid`) rather than tip-to-tip when the base branch has advanced past the merge base, and asserts stale/mismatched base OIDs and a head force-push during collection produce a partial profile without source substitution |
| `tests/test-risk-signals.sh` | Asserts exact values for every deterministic signal against that fixture, including rename-aware base history, verified author familiarity in `true`, `false`, and `unknown` states, bounded fix-keyword matching that excludes subjects such as `Fixture updates`, `fix_commits / commits`, the five-commit eligibility rule, the versioned `is_code` and `is_test_source` predicates for docs-only, fixture-heavy, and mixed PRs, and unavailable-signal behavior. No network, no `claude`. |
| `tests/test-risk-scoring.sh` | Feeds fixture signal sets to the scoring function and asserts score, tier, full breakdown, every cap boundary, zero-test precedence, the sub-0.05-ratio bands at both 1–49 and ≥50 code lines, the disjoint familiarity-gap boundaries, source-only test-line accounting, and both defect-density boundaries |
| `tests/test-path-classes.sh` | Asserts base-only pin loading, pin-plus-current-class union, nonempty class/evidence requirements, semantic-evidence validation, resolution order (pin + cache/model → unclassified), cache identity/version/base-path/merge-base-blob/per-file-diff/evidence fingerprint rejection, repository namespace isolation, atomic concurrent cache updates, and that only complete current-change cache coverage skips call A |
| `tests/test-risk-remote-safety.sh` | Asserts protected policy loading, a PR cannot self-authorize egress, tenant-identity mismatch denial, exact-payload secret-detection no-egress (including final diff), byte/file/hunk/token/timeout/cost limits, malformed output rejection, and that prompt-like PR text cannot produce executable actions |
| `tests/test-risk-report.sh` | Renders fixture `risk-profile.json` to markdown; asserts `agent_safe` rejects changed-path mismatches, sensitive, `other`, and `unclassified` entries; asserts validation applicability and `signals_unavailable` are always rendered |
| `tests/test-risk-output.sh` | Runs `--enrich --risk` with controlled parallel results; asserts one serialized combined-data/report write, atomic artifacts, and the producer side of the shared `schema_version: 1` fixture consumed by the separately owned `xray` contract test |

Test hooks follow the existing environment-variable pattern (`TEST_COMPUTE_SIGNALS_DIR`,
`TEST_SCORE_SIGNALS_FILE`, `TEST_RENDER_RISK_FILE`) but call the real functions rather than
inlined copies.

`.github/workflows/test.yml` gains a step per new test file.

## Documentation

**`SKILL.md`** gains the risk decision record: `high` and `critical` require human
acknowledgement and a change-type-aware verification decision while thresholds remain
uncalibrated. Every `validation_required[]` item requires observed applicable verification or a
reviewed not-applicable reason before work is declared complete. It documents how to read
`risk-profile.json` and treats `agent_safe` as a constrained allow-list, never authority for
unclassified or unevidenced work.

**`README.md`** gains `--risk` and `--risk-remote`, output files and their schema contract, the
taxonomy table, pin-file format, source-snapshot rules, remote opt-in/private-repository policy,
data limits and retention metadata, and an explicit statement of what the signals do and do not
mean.

## Non-goals

- No real import-graph resolution. Reference counts are textual.
- No coverage-data integration. Test deficit is measured in changed lines, not covered lines.
- No score calibration loop. `retrospective` integration is future work.
- No changes to `--enrich`, `watch`, `address`, or `resolve` behavior beyond the shared diff fetch
  and the function-ordering refactor.
- No automatic execution of model recommendations, rollback commands, or agent delegation.

## Future work

Record predicted tier, completeness, required verification, the operator's verification decision,
and outcome — whether a PR was reverted or hotfixed within N days. Feed that into
`retrospective` to tune the thresholds in the scoring table against evidence rather than
intuition. A future decision may make calibrated tiers completion gates only after an explicit
sample-size, false-positive, and false-negative evaluation.
