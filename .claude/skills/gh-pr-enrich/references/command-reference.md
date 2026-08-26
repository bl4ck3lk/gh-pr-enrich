# gh-pr-enrich Command Reference

Syntax, options, environment variables, output files, prompt customization
and troubleshooting. Read this when you need a flag or a file path — the
workflow itself stays in SKILL.md.

## Prerequisites

- GitHub CLI (`gh`) authenticated with repo access
- `jq` installed for JSON processing
- `gh pr-enrich` extension installed: `gh extension install bl4ck3lk/gh-pr-enrich`
- For external Claude enrichment: [Claude CLI](https://claude.ai/code) installed and authenticated

## Quick Start

```bash
# Install the extension (one-time)
gh extension install bl4ck3lk/gh-pr-enrich

# Basic PR analysis
gh pr-enrich 123

# Prepare context for Codex native subagents
gh pr-enrich 123 --prepare-analysis --diff --sast

# Add an external Claude pass (public repository)
gh pr-enrich 123 --enrich --diff

# Private/internal repository, after explicit disclosure authorization
gh pr-enrich 123 --enrich --allow-external --diff

# JSON output for scripting
gh pr-enrich 123 --json
```

## Command Reference

### Syntax

```bash
gh pr-enrich <PR_NUMBER> [OPTIONS]
gh pr-enrich <SUBCOMMAND> [ARGS]
```

### Subcommands

| Subcommand | Description |
|------------|-------------|
| `install-skill [--runtime codex\|claude\|both]` | Install one canonical skill under `${CODEX_HOME:-$HOME/.codex}/skills/` and/or `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/` (default: both) |
| `uninstall-skill [--runtime codex\|claude\|both]` | Remove selected runtime registrations |
| `select-analysis <REPORT_DIR> <SOURCE_JSON>` | Recheck the hosted PR head, promote a Codex, Claude, or hybrid result, and refresh all selected views |
| `resolve <ID...>` | Resolve one or more review threads by GraphQL ID |
| `watch <PR>` | Monitor a PR for new comments (`--interval MIN`, `--enrich`, `--notify`) |
| `address <PR>` | Work through selected issues and recheck the hosted head before resolving threads; legacy reports are read-only |
| `retrospective` | Cross-PR pattern analysis (see "Retrospective Analysis" below) |

### Options

| Option | Description |
|--------|-------------|
| `--json` | Output only JSON (for scripting) |
| `--markdown` | Output only Markdown report |
| `--output-dir DIR` | Custom output directory |
| `--prepare-analysis` | Write provider-neutral context and schema for Codex or another analyzer |
| `--enrich` | Run external Claude analysis on unresolved threads and issue comments |
| `--allow-external` | Authorize external Claude disclosure for private/internal/unknown visibility |
| `--diff` | Fetch code diffs and include them in provider-neutral context; implies preparation |
| `--sast` | Run a semgrep pre-pass on changed files; rule matches enter the analysis as evidence to verify |
| `--no-code-access` | Deny the analyzer repository access (sandboxed runs). Findings can then only be `plausible` |
| `--code-access` | Read the working tree even when it is not at the PR head. Findings may cite code this PR does not contain |
| `--model NAME` | Model for the analysis (default: `sonnet`) |
| `--prompt FILE` | Custom prompt file for AI analysis |
| `-h, --help` | Show help |
| `-v, --version` | Show version |

**Recommended Codex path:** `gh pr checkout <N>` first, then `gh pr-enrich <N> --prepare-analysis --diff --sast`, followed by native-subagent analysis. Add `--enrich` only when an external Claude pass is wanted.

**Repository access depends on the revision you have checked out.** Verifying a claim means reading the PR's code, so the extension compares your working tree to the PR head:

| Working tree | Behavior |
|---|---|
| At the PR head | Access granted; findings can be `confirmed` |
| Ahead of the PR head (your local fixes) | Access denied unless `--code-access` explicitly exposes the local commits |
| An unrelated revision (e.g. you are on `main`) | Access **denied**; run `gh pr checkout <N>`, or pass `--code-access` to analyze the tree as it is |
| Not a git checkout | Access denied |

Automatic access also requires a clean tree with no ignored files. Generated
report artifacts are excluded only after their directory is checked against the
closed output allowlist; tracked changes inside an output directory still deny
access. Tracked symlinks, gitlinks/submodules, and other non-regular index
entries are not materialized; repositories containing them run without code
access.

`--code-access` (or `GH_PR_ENRICH_CODE_ACCESS=true`) overrides revision, dirty-tree,
and unknown-PR-head denials. A Git checkout is still required because the
extension must fingerprint and materialize an immutable repository snapshot.
`--no-code-access` wins over every override.

Analyzing PR #123 from `main` without this check produced confident verdicts and `file:line` anchors for code the PR does not contain. The decision, both revisions and the reason are recorded in the coverage block and the report.

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `PR_REVIEW_OUTPUT_ROOT` | Override default output directory root |
| `GH_PR_ENRICH_PROMPT` | Path to custom prompt file for Claude analysis |
| `GH_PR_ENRICH_MODEL` | Model for the analysis (default: `sonnet`) |
| `GH_PR_ENRICH_CODE_ACCESS` | `false` disables repository read access; `true` forces it on a revision mismatch |
| `GH_PR_ENRICH_TRUNCATE_CHARS` | Per-text-input truncation limit for comments, intent bodies and diffs (default: 5000) |
| `GH_PR_ENRICH_SEMGREP_CONFIG` | `semgrep --config` value for `--sast` (default: `auto`) |
| `GH_PR_ENRICH_SEMGREP_TIMEOUT` | Seconds allowed for the semgrep pre-pass (default: 180) |
| `GH_PR_ENRICH_HEARTBEAT_SECONDS` | Seconds between "still analyzing" progress lines (default: 60) |
| `CLAUDE_TIMEOUT` | Timeout in seconds for Claude analysis (default: 600 for PR analysis, 180 for retrospective) |

**Timeouts:** verifying against code takes longer than summarizing comments. A large PR analyzed with `--diff` can exceed the 600s default; raise `CLAUDE_TIMEOUT` rather than dropping code access, since a timed-out run produces no analysis at all.

## Output Files

Default location: `.reports/pr-reviews/pr-<NUMBER>/`

| File | Description |
|------|-------------|
| `comprehensive-report.md` | Human-readable summary of PR |
| `combined-data.json` | Complete machine-readable data |
| `pr-summary.json` | PR metadata (title, body, author, files) |
| `all-comments.json` | All comments combined |
| `issue-comments.json` | Top-level PR comments (part of the enrichment context) |
| `review-comments.json` | Top-level review summaries (part of the enrichment context) |
| `inline-comments.json` | Inline REST comments (part of the enrichment context) |
| `comment-threads.json` | Thread data with GraphQL IDs and `isResolved` status |
| `checks.json` | CI/CD status information |
| `linked-issues.json` | Issues this PR closes (intent the diff cannot show) |
| `analysis-context.json` | Provider-neutral immutable snapshot, including `coverage` |
| `analysis-schema.json` | Shared structured-output schema for Codex and Claude |
| `analysis.json` | Selected provider-neutral result used by downstream commands |
| `analysis.md` | Human-readable selected analysis |
| `codex-analysis.json` | Codex root synthesis of native-subagent returns |
| `hybrid-analysis.json` | Root-verified Codex + Claude synthesis |
| `claude-analysis.json` | Exact external Claude source artifact; never relabeled as Codex |
| `claude-analysis.md` | Human-readable Claude source report |
| `claude-context.json` | Compatibility copy of `analysis-context.json` |
| `claude-stderr.log` | (if --enrich) Analyzer stderr — read this first when an analysis comes back empty |
| `context-coverage.md` | (if --enrich) Rendered table of what was truncated, dropped or omitted |
| `pr-diff.txt` / `pr-diff.json` | (if --diff) Raw and per-file structured diff |
| `sast-findings.json` | (if --sast) Normalized semgrep findings |

## Customizing the Analysis Prompt

The prompt is loaded from (in priority order):
1. `--prompt FILE` argument
2. `GH_PR_ENRICH_PROMPT` environment variable
3. `default-prompt.txt` bundled with the extension

Repository-owned prompt files are not loaded implicitly because PR branches are
untrusted. Use `--prompt` for a reviewed repository-specific prompt.

If none is found the run fails rather than falling back to a built-in prompt: the
prompt and the JSON schema are one contract, and a prompt describing a different
contract steers the model one way while validating it another.

**Prompt file format:**
- Lines starting with `#` are comments (ignored)
- Remaining text becomes the system prompt
- Must produce every section the schema requires: `issue_categories`,
  `category_coverage`, `disputed_comments`, `systemic_issues`,
  `adjacent_problems`, `task_list`, `process_improvements`,
  `pr_template_suggestions`
- Must use the closed 16-category list; a category outside the enum is rejected
- Must instruct verdicts, confidence and file:line evidence, or findings arrive
  unverified

**Example custom prompts:**

| Focus | Key Instructions |
|-------|------------------|
| Security | Focus on OWASP Top 10, auth issues, input validation |
| Performance | Focus on N+1 queries, memory leaks, render cycles |
| Architecture | Focus on coupling, abstraction layers, patterns |
| Documentation | Focus on missing docs, incorrect comments, API clarity |

## Troubleshooting

### Extension Not Found

```bash
# Install or upgrade
gh extension install bl4ck3lk/gh-pr-enrich
gh extension upgrade pr-enrich
```

### Claude Analysis Skipped

If `--enrich` reports "No unresolved threads or issue comments found":
- Enrichment runs when the PR has unresolved review threads OR top-level issue comments; with neither, it is skipped
- All review threads may already be resolved — check `comment-threads.json` to verify thread status
- Check `issue-comments.json` to confirm the PR has no top-level comments

### External Claude Analysis Empty

If analysis returns empty arrays:
- Verify Claude CLI is authenticated: `claude --version`
- Check the context file was created: `jq '.coverage' analysis-context.json`
- Try with a custom, simpler prompt to debug

### Thread Resolution Fails

**Common failure modes and recovery:**

| Error | Cause | Recovery |
|-------|-------|----------|
| `NOT_FOUND` | Thread ID is wrong or from a different PR | Re-fetch `comment-threads.json` and verify the ID |
| `FORBIDDEN` | Insufficient permissions | Check you have write access to the repo |
| Already resolved | Thread was resolved by another actor | Safe to skip — verify with a fresh query |
| Network error | Transient failure | Retry once. If persistent, check `gh auth status` |

```bash
# Verify thread ID exists
jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.id == "PRRT_xxx")' \
  comment-threads.json

# Check if already resolved
jq '.data.repository.pullRequest.reviewThreads.nodes[]
    | select(.id == "PRRT_xxx") | .isResolved' comment-threads.json
```
