# gh-pr-enrich

A GitHub CLI extension for comprehensive PR context and evidence-driven analysis with Codex native subagents, optional external Claude, or both.

## Features

- 📋 **Complete PR Details**: Summary, files, labels, assignees, reviewers
- 💬 **All Comments**: Issue comments, review comments, inline code comments
- 🧵 **Thread Tracking**: GraphQL IDs for programmatic thread resolution
- ✅ **CI/CD Status**: Check runs and status information
- 📊 **Statistics**: Comment counts by type/user, recent activity
- 🧩 **Provider-neutral context**: Builds one revision-bound snapshot and schema for Codex, Claude, or another analyzer
- 🤖 **Codex native-subagent analysis**: The included skill splits review lenses across current-session Codex subagents and keeps the root agent responsible for synthesis
- 🧠 **External Claude analysis** (optional): Runs a separate read-only verification pass with explicit private-data disclosure controls
- 🔬 **Static Analysis Pre-pass** (optional): `--sast` runs semgrep over the changed files so the analysis starts from deterministic findings
- 🔧 **Thread Resolution**: Resolve comment threads directly from CLI
- 👀 **Watch Mode**: Monitor PRs for new comments with auto-analysis
- 🎯 **Interactive Mode**: Work through issues one by one with guided fixing
- 🧠 **Codex + Claude skill**: One canonical skill installs into both runtimes

## Installation

```bash
gh extension install bl4ck3lk/gh-pr-enrich
```

## Usage

```bash
# Basic PR report
gh pr-enrich 123

# Prepare a shared snapshot for Codex native subagents
gh pr-enrich 123 --prepare-analysis --diff --sast

# Add an external Claude pass on a public repository
gh pr-enrich 123 --enrich --diff

# Private/internal repository: only after explicit disclosure authorization
gh pr-enrich 123 --enrich --allow-external --diff --sast

# Output JSON only (for scripting)
gh pr-enrich 123 --json

# Custom output directory
gh pr-enrich 123 --output-dir ./my-reports

# Resolve comment threads by ID
gh pr-enrich resolve PRRT_xxx PRRT_yyy

# Watch a PR for new comments (checks every 5 min by default)
gh pr-enrich watch 123 --interval 2 --enrich

# Interactive mode to work through issues
gh pr-enrich address 123
```

## Options

| Option | Description |
|--------|-------------|
| `--json` | Output only JSON |
| `--markdown` | Output only Markdown |
| `--output-dir DIR` | Custom output directory |
| `--prepare-analysis` | Build provider-neutral context and schema without an external analyzer |
| `--enrich` | Run external Claude analysis on unresolved threads and issue comments |
| `--allow-external` | Authorize external Claude disclosure for private/internal/unknown visibility |
| `--diff` | Include code diffs in provider-neutral context; implies preparation |
| `--sast` | Run a semgrep pre-pass over changed files and feed the findings to the analysis |
| `--no-code-access` | Deny the analyzer repository access (sandboxed runs); findings can then only be `plausible` |
| `--code-access` | Read the working tree even when it is not at the PR head |
| `--model NAME` | Model for the analysis (default: `sonnet`) |
| `--prompt FILE` | Custom prompt file for Claude analysis |
| `-h, --help` | Show help |
| `-v, --version` | Show version |

## Subcommands

| Subcommand | Description |
|------------|-------------|
| `install-skill [--runtime codex\|claude\|both]` | Install the canonical skill for Codex and/or Claude Code (default: both) |
| `uninstall-skill [--runtime codex\|claude\|both]` | Remove selected runtime registrations |
| `select-analysis <REPORT_DIR> <SOURCE_JSON>` | Recheck the hosted PR head, promote a Codex, Claude, or hybrid result, and refresh derived views |
| `resolve <ID...>` | Resolve one or more PR review threads by GraphQL ID |
| `watch <PR>` | Monitor PR for new comments (options: `--interval`, `--enrich`, `--notify`) |
| `address <PR>` | Work through selected issues; recheck the hosted head before resolving threads |
| `retrospective` | Analyze patterns across all PRs (options: `--since`, `--author`, `--enrich`, `--format`) |

## Output Files

When run, the extension creates a directory with:

```
.reports/pr-reviews/pr-123/
├── comprehensive-report.md      # Human-readable summary
├── combined-data.json           # Machine-readable data
├── pr-summary.json              # PR metadata
├── all-comments.json            # All comments combined
├── issue-comments.json          # Top-level PR comments (part of enrichment context)
├── comment-threads.json         # Thread data with GraphQL IDs
├── checks.json                  # CI/CD status
├── linked-issues.json           # Issues this PR closes
├── analysis-context.json        # Shared immutable snapshot and coverage
├── analysis-schema.json         # Shared structured-output contract
├── analysis.json                # Selected result for downstream consumers
├── analysis.md                  # Human-readable selected result
├── codex-analysis.json          # (Codex workflow) Native-subagent synthesis
├── hybrid-analysis.json         # (hybrid workflow) Root-verified merged result
├── claude-analysis.json         # (if --enrich) Claude output with exact-head provenance
├── claude-analysis.md           # (if --enrich) Claude source report
├── claude-context.json          # Compatibility copy of analysis-context.json
├── claude-stderr.log            # (if --enrich) Analyzer stderr
├── context-coverage.md          # (if --enrich) What was truncated, dropped or omitted
├── sast-findings.json           # (if --sast) Normalized semgrep findings
├── pr-diff.txt                  # (if --diff) Raw unified diff
└── pr-diff.json                 # (if --diff) Structured diff by file
```

Intermediate artifacts (`review-comments.json`, `inline-comments.json`, `unresolved-threads.json`, `issue-comments-deduped.json`, `claude-raw-response.json`, `id-mapping.txt`) are also kept in the same directory for debugging.

When an analysis comes back empty, read `claude-stderr.log` first — an empty result is usually a failed or timed-out run, not a clean PR.

## Retrospective Analysis

The `retrospective` subcommand analyzes patterns across all your PR reports to identify systemic issues and generate actionable insights.

```bash
# Basic retrospective (analyzes all PRs in .reports/pr-reviews)
gh pr-enrich retrospective

# Analyze PRs from the last 30 days
gh pr-enrich retrospective --since 30d

# Filter by author
gh pr-enrich retrospective --author alice,bob

# With external Claude meta-analysis (explicit because reports may be private)
gh pr-enrich retrospective --enrich --allow-external

# Output formats for integration
gh pr-enrich retrospective --format claude-md    # CLAUDE.md section
gh pr-enrich retrospective --format checklist    # Implementation checklist
gh pr-enrich retrospective --format pr-template  # PR template additions
```

### Retrospective Options

| Option | Description | Default |
|--------|-------------|---------|
| `--since DATE` | Filter PRs from date (ISO 8601 or `30d`, `2w`, `3m`) | All |
| `--author LOGIN` | Filter by author(s), comma-separated | All |
| `--reports-dir DIR` | Path to reports directory | `.reports/pr-reviews` |
| `--output-dir DIR` | Where to save output | `.reports/retrospectives` |
| `--enrich` | Use Claude for meta-analysis | false |
| `--min-prs N` | Warn if fewer PRs found | 3 |
| `--format TYPE` | Output format: `claude-md`, `pr-template`, `checklist` | - |
| `--json` | Output JSON only | - |
| `--markdown` | Output Markdown only | - |

### Retrospective Output

The retrospective generates:

- **Cross-PR Patterns**: Issues that repeat across multiple PRs with occurrence counts
- **Category Hotspots**: Issue/task categories receiving the most review feedback
- **Guiding Questions**: Checklist derived from recurring issues
- **Improvement Tracking**: Process suggestions made across PRs
- **Team Summary**: High-level stats for sprint retrospectives

With `--enrich`, Claude provides additional meta-analysis:

- Root causes behind recurring patterns
- Knowledge gaps the team should address
- Automation opportunities (linting, CI checks)
- Refined guiding questions by development phase

## Analysis and External Claude

`--prepare-analysis` creates `analysis-context.json` and
`analysis-schema.json` without calling an external model. In Codex, the
installed skill gives that exact snapshot to native subagents with independent
review lenses; the root agent verifies and synthesizes their returns into
`codex-analysis.json` or `hybrid-analysis.json`.

When using `--enrich`, Claude reads the PR context — unresolved review threads,
top-level review summaries, issue and inline comments (including bot/CI reports),
commit messages, linked issue bodies, and failing checks — and, when the checkout
passes the access gate, reads the repository itself to check claims against code.

The result is a verification pass, not a summary:

- **Issue Categories**: Each finding carries a `verdict` (`confirmed` / `plausible` / `refuted`), a `confidence`, and `evidence` naming the file and line that was inspected
- **Disputed Comments**: Reviewer or bot claims that were checked and found wrong, with the reason
- **Category Coverage**: An explicit verdict for each of the 16 categories, so "not checked" never looks like "clean"
- **Systemic Issues**: Patterns behind several findings, with the evidence that links them
- **Adjacent Problems**: Related areas, flagged with whether the analyzer actually searched them
- **Task List**: Prioritized actions, each with `file`, `line`, `suggested_fix` and a `verification` command
- **Process Improvements**: Automation, documentation, and review-process suggestions to prevent recurrence
- **PR Template Suggestions**: Checklist items that would catch these issues before review

Severity is derived from **impact × likelihood**, never from the category — a bug raised inside a style nit still ranks as a bug.

The analysis runs when the PR has unresolved threads, review summaries, issue
comments, or inline comments; if it has none, enrichment is skipped.

### The 16 categories

`logic_error`, `boundary_condition`, `concurrency`, `error_handling`, `resource_lifecycle`, `security`, `secrets_exposure`, `data_integrity`, `api_contract`, `performance`, `test_gap`, `observability`, `maintainability`, `documentation`, `build_ci`, `dependency_risk`

The list is closed, and the analysis must return a verdict for every one of them.

### Requirements for `--enrich`

- [Claude CLI](https://claude.ai/code) must be installed and authenticated
- Private/internal/unknown-visibility repositories require separate explicit user authorization and `--allow-external`.
- The analyzer is restricted to **read-only** tools (Read, Grep, Glob). It never runs commands and never edits files. Use `--no-code-access` to withhold even that.
- Claude uses a non-interactive permission mode, bypasses plugins, and does not persist the analysis session.
- Automatic access is granted only when the working tree is clean, contains no
  ignored files, and is exactly at the PR head. Dirty, ahead, and unrelated
  checkouts are denied because repository tools could expose local-only files or
  verify the wrong revision. Run `gh pr checkout <N>` first. `--code-access` is
  an explicit override that exposes the current workspace despite those checks.
- Every selected result is bound to a recomputed SHA-256 digest of the analysis
  context. Failed comment, thread, check, or linked-issue fetches remain visible
  in coverage and prevent publication of a clean selected verdict.
- Verification takes longer than summarizing. The default timeout is 600s; raise `CLAUDE_TIMEOUT` for large PRs.

### Customizing the Analysis Prompt

The Claude analysis prompt can be customized through explicit operator-controlled inputs. The extension looks for prompts in this order:

1. `--prompt FILE` command-line argument
2. `GH_PR_ENRICH_PROMPT` environment variable
3. `default-prompt.txt` bundled with the extension

Repository-owned prompt files are not loaded automatically. A pull-request branch is
untrusted input and must not be able to replace the bundled injection and tool-safety
rules. Pass a reviewed file with `--prompt` when a repository needs custom coverage.

To customize, copy the default prompt and modify it:

```bash
# Find extension directory
EXTENSION_DIR=$(dirname $(which gh-pr-enrich 2>/dev/null || echo ~/.local/share/gh/extensions/gh-pr-enrich/gh-pr-enrich))

# Copy the default prompt to an operator-controlled location
cp "$EXTENSION_DIR/default-prompt.txt" "$HOME/.config/gh-pr-enrich-prompt.txt"

# Select it explicitly
export GH_PR_ENRICH_PROMPT="$HOME/.config/gh-pr-enrich-prompt.txt"
```

**Prompt file format:**
- Lines starting with `#` are comments (ignored)
- The remaining text becomes the system prompt for Claude
- See `default-prompt.txt` for the expected format

## Dependencies

| Tool | Required | Install |
|------|----------|---------|
| `gh` | ✅ Yes | `brew install gh` |
| `jq` | ✅ Yes | `brew install jq` |
| `claude` | Only for `--enrich` | [claude.ai/code](https://claude.ai/code) |
| `semgrep` | Only for `--sast` | `pip install semgrep` |

## Environment Variables

```bash
# Override default output directory
export PR_REVIEW_OUTPUT_ROOT="./custom-reports"

# Custom prompt file for Claude analysis
export GH_PR_ENRICH_PROMPT="$HOME/.config/gh-pr-enrich-prompt.txt"

# Timeout for Claude analysis (default: 600s for PR analysis, 180s for retrospective)
export CLAUDE_TIMEOUT=1200  # 20 minutes, for large PRs

# Model used for the analysis (default: sonnet)
export GH_PR_ENRICH_MODEL=opus

# Run the analysis without repository read access (sandboxed/offline)
export GH_PR_ENRICH_CODE_ACCESS=false

# Per-comment and per-file-diff truncation limit (default: 5000 characters)
export GH_PR_ENRICH_TRUNCATE_CHARS=8000

# Seconds between "still analyzing" progress lines during a long analysis
export GH_PR_ENRICH_HEARTBEAT_SECONDS=30

# semgrep configuration and time budget for --sast
export GH_PR_ENRICH_SEMGREP_CONFIG="p/ci"
export GH_PR_ENRICH_SEMGREP_TIMEOUT=300
```

## Examples

### Analyze a PR and get structured output

```bash
gh pr-enrich 123 --json | jq '.statistics.comments'
```

### Get unresolved thread IDs

```bash
gh pr-enrich 123
jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .id' \
  .reports/pr-reviews/pr-123/comment-threads.json
```

### Resolve comment threads

```bash
# Resolve a single thread
gh pr-enrich resolve PRRT_xxx

# Resolve multiple threads at once
gh pr-enrich resolve PRRT_xxx PRRT_yyy PRRT_zzz
```

### Monitor a PR for new comments

```bash
# Watch with 2-minute intervals and auto-analyze new comments
gh pr-enrich watch 123 --interval 2 --enrich

# Private/internal repository, after disclosure authorization
gh pr-enrich watch 123 --interval 2 --enrich --allow-external

# Watch with desktop notifications (macOS)
gh pr-enrich watch 123 --notify
```

### Work through issues interactively

```bash
# Requires analysis.json from a Codex/hybrid run, or a previous --enrich run
gh pr-enrich 123 --enrich # public repository example
gh pr-enrich address 123

# Controls: [f]ixed, [s]kip, [o]pen in browser, [q]uit
```

## Codex and Claude Code Skill

This extension includes one canonical skill for Codex and Claude Code. It prepares one snapshot, assigns read-only analysis lenses, and preserves provider attribution through final synthesis.

### Installing the Skill

```bash
gh pr-enrich install-skill
```

This registers the same source at `~/.codex/skills/gh-pr-enrich` and `~/.claude/skills/gh-pr-enrich`. Use `--runtime codex` or `--runtime claude` to install only one.

To uninstall:
```bash
gh pr-enrich uninstall-skill
```

### What the Skill Provides

Once installed, Codex or Claude Code can:

- **Fetch and analyze PRs** when you ask to "analyze PR #123" or "review PR comments"
- **Use Codex native subagents** for independent category lenses in the current session
- **Add an external Claude pass** without giving Claude write or command tools
- **Synthesize hybrid results** with exact-head and provider provenance
- **Interpret analysis results** - understands issue categories, systemic patterns, and task lists
- **Work with thread IDs** - find, filter, and resolve comment threads programmatically
- **Create task lists** from the prioritized AI analysis
- **Customize prompts** for security-focused, performance-focused, or other specialized reviews

### Example usage

```
> Use gh-pr-enrich to analyze PR 42 and create a todo list from critical issues

> Use Codex native subagents plus Claude to review PR 42, then synthesize a hybrid report

> Read analysis.json and address each confirmed high-priority task

> What systemic patterns were found in the PR review?
```

### Skill Location

The canonical skill is `.claude/skills/gh-pr-enrich/SKILL.md`; `.agents/skills/gh-pr-enrich/SKILL.md` is the project-local Codex adapter. Both installers point to the canonical source.

## Development

Run the test suite (CI runs the same scripts on every push and PR):

```bash
tests/run-all.sh                  # All runtime, contract, security, and workflow suites
```

Design specs for planned features live in `docs/superpowers/specs/` (currently the PR risk profile contract for a future `--risk` flag; not yet implemented).

## License

MIT
