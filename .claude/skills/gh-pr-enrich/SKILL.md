---
name: gh-pr-enrich
description: Use when reviewing a PR, addressing PR review feedback, investigating review comments or bot/CI reports on a PR, auditing a PR for bugs before merge, or looking for recurring issues across past PRs.
---

# gh-pr-enrich Skill

Comprehensive PR analysis using the `gh pr-enrich` GitHub CLI extension. Fetches complete PR context (comments, threads, checks, commits, linked issues) and optionally runs a verification pass with Claude that checks each claim against the code, sweeps a fixed category list, and produces anchored, executable tasks.

## Why This Skill Exists (RED Baseline)

Without this skill, agents addressing PR feedback fall into predictable failure modes:

| What agents do without gh-pr-enrich | What gh-pr-enrich prevents |
|--------------------------------------|---------------------------|
| Treat every review comment as correct | Each finding carries a verdict; refuted claims land in `disputed_comments` |
| Fix only what reviewers noticed | Fixed category sweep with an explicit verdict per category |
| Rank a bug as "low" because it arrived as a style note | Severity derives from impact × likelihood, never from category |
| Produce vague tasks ("improve error handling") | Every task carries file, line, suggested fix and a verification step |
| Read comments one at a time, miss patterns | Groups issues by category, surfaces systemic root causes |
| Fix symptoms without investigating adjacent code | Adjacent problems are checked, and marked when they were not |
| Address tasks then forget to resolve threads | Mandatory thread resolution workflow with final audit |
| Declare "done" without verifying CI | Completion gate requires `gh pr checks` evidence |
| Miss non-thread comments entirely | Explicit non-thread comment check in workflow |
| Trust a truncated report as a complete one | Coverage block records every dropped or shortened input |
| Treat each PR in isolation | Retrospective analysis connects patterns across PRs |

**The gap:** A general-purpose agent addressing PR feedback accepts reviewer claims as facts, fixes only what was pointed out, forgets to resolve threads, and skips CI verification. This skill makes each of those failures visible.

## When to Use This Skill

Use this skill when:
- User asks to "analyze PR #X" or "review PR comments"
- Addressing PR feedback and need structured view of unresolved issues
- Investigating review comment patterns across a PR
- Need to understand the full context of PR discussions
- Want to identify systemic issues from reviewer feedback
- Creating a task list from PR review comments
- User asks for "team retrospective", "analyze patterns", or "recurring issues"
- Need to generate CLAUDE.md additions from PR feedback history
- Want to create implementation checklists from past reviews

## Required Analysis Workflow

**IMPORTANT:** After running `gh pr-enrich --enrich`, you MUST complete these steps before addressing individual tasks:

### 0. Separate Verified Findings from Claims (REQUIRED)

Every finding carries a `verdict`. Read it before you plan any work:

```bash
ANALYSIS=.reports/pr-reviews/pr-<NUMBER>/claude-analysis.json

# Findings that were traced in the code
jq '[.issue_categories[] | select(.verdict == "confirmed")]' "$ANALYSIS"

# Findings that could not be verified — investigate before fixing
jq '[.issue_categories[] | select(.verdict == "plausible")]' "$ANALYSIS"

# Reviewer or bot claims that were checked and found wrong
jq '.disputed_comments' "$ANALYSIS"
```

**Why this matters:** A review comment is a claim, not a fact. Fixing a refuted claim changes working code for no reason and closes the thread with a false explanation.

- `confirmed` → fix it.
- `plausible` → verify it yourself first, then fix or dispute.
- `refuted` / listed in `disputed_comments` → **do not fix.** Reply on the thread with the reason it does not apply, and resolve only after the reviewer agrees.

### 0b. Check What Was Actually Swept (REQUIRED)

```bash
# Categories the analyzer could not check, and why
jq '[.category_coverage[] | select(.verdict == "not_reviewable")]' "$ANALYSIS"

# What the analyzer was and was not shown
jq '.analysis_context_coverage' .reports/pr-reviews/pr-<NUMBER>/combined-data.json
```

**Why this matters:** "No findings" and "not checked" look identical in a task list. `not_reviewable` categories and truncated inputs are the gaps where bugs survive a clean-looking review. If a category you care about is `not_reviewable`, review it yourself or re-run with `--diff` and repository access.

### 1. Review Systemic Issues (REQUIRED)

Always check `systemic_issues` first. These reveal root causes that may affect multiple tasks:

```bash
jq '.systemic_issues' .reports/pr-reviews/pr-<NUMBER>/claude-analysis.json
```

**Why this matters:** Individual comments are often symptoms of deeper patterns. Fixing the systemic issue may resolve multiple tasks at once, or inform how you approach each fix.

### 2. Investigate Adjacent Problems (REQUIRED)

Always review `adjacent_problems` to identify related areas that need attention:

```bash
jq '.adjacent_problems' .reports/pr-reviews/pr-<NUMBER>/claude-analysis.json

# The ones the analyzer could not search itself — these are yours to check
jq '[.adjacent_problems[] | select(.checked != true)]' .reports/pr-reviews/pr-<NUMBER>/claude-analysis.json
```

**Why this matters:** PR reviewers see only the changed code. Adjacent problems highlight areas with similar issues that weren't in the PR diff. Investigating these prevents:
- Incomplete fixes that miss related code
- Future PRs with the same feedback
- Whack-a-mole debugging cycles

`checked: true` means the analyzer searched and reported what it found. `checked: false` means it could not search — treat that as an open investigation, not a clean result.

### 3. Then Address Tasks in Priority Order

Only after completing steps 1-2 should you work through the `task_list`. Your understanding of systemic issues and adjacent problems should inform how you implement each fix.

**DO NOT** skip to the task list without reviewing systemic issues and adjacent problems first.

### 4. Resolve Addressed Threads (REQUIRED)

After fixing each task, you MUST reply to and resolve the corresponding review threads immediately. Do NOT batch this to the end — resolve threads as you go so progress is visible to reviewers.

**Reply first, then resolve.** Reviewers expect acknowledgment before resolution. A silent resolve feels dismissive and makes it hard to verify the fix.

```bash
# Step A: Reply to the thread with what you did
THREAD_ID="PRRT_xxx"
gh api graphql -f query='mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) {
    comment { id }
  }
}' -f threadId="$THREAD_ID" -f body="Fixed in $(git rev-parse --short HEAD) — [brief description of the fix]"

# Step B: Then resolve the thread (same variable as Step A)
gh pr-enrich resolve "$THREAD_ID"
# For multiple threads, pass each ID as a separate argument: gh pr-enrich resolve PRRT_xxx PRRT_yyy
```

**After all tasks are complete**, verify no threads were missed (assumes `$OWNER`, `$REPO`, `$PR_NUMBER` were resolved earlier — see "Resolving Owner, Repo, and PR Number"):

```bash
# Re-fetch thread status and check for any still-unresolved threads.
# --paginate follows the cursor: a PR with more than 100 threads must not lose the rest.
gh api graphql --paginate -F owner="$OWNER" -F repo="$REPO" -F number="$PR_NUMBER" -f query='
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { id isResolved }
      }
    }
  }
}' | jq -s '[.[].data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)]'
```

**Always use `--paginate` with `jq -s`.** A single page silently caps the audit at 100 threads, and a missed thread reads exactly like a resolved one.

If any threads remain unresolved, investigate whether they were:
- **Addressed but not resolved** — resolve them now
- **Intentionally left open** — leave a reply explaining why (e.g., "Will address in follow-up PR #X")
- **Out of scope** — leave a reply stating the rationale

**DO NOT** declare work complete while addressed threads remain unresolved. Unresolved threads block PR approval and signal to reviewers that feedback was ignored.

### 5. Verify CI/CD Checks Pass (REQUIRED)

After all fixes are committed and pushed, you MUST verify that all GitHub Actions and status checks pass. Do NOT assume your changes didn't break CI.

```bash
# Check current status of all checks on the PR
gh pr checks "$PR_NUMBER"
```

**Interpret the results:**
- All checks pass → proceed to notify reviewers
- Any check fails → investigate and fix before declaring work complete
- Checks pending → wait and re-check (use `gh pr checks "$PR_NUMBER" --watch` or poll)

**If a check fails:**

```bash
# Get details on the failing check
gh run list --branch <BRANCH_NAME> --limit 5
gh run view <RUN_ID> --log-failed
```

1. Read the failure logs
2. Determine if the failure is related to your changes or a flaky/pre-existing issue
3. If related to your changes — fix, commit, push, and re-verify
4. If pre-existing/flaky — document it in a PR comment so reviewers have context

**DO NOT** request re-review or declare work complete while checks are failing. Failed checks block merge and waste reviewer time.

## Resolving Owner, Repo, and PR Number

Many commands in this skill require `OWNER`, `REPO`, and `PR_NUMBER`. Resolve these from git context at the start of every session:

```bash
# Extract owner and repo from the current git remote
OWNER=$(gh repo view --json owner -q '.owner.login')
REPO=$(gh repo view --json name -q '.name')

# If working on the current branch's PR:
PR_NUMBER=$(gh pr view --json number -q '.number')

# Or specify directly:
PR_NUMBER=123
```

**Always resolve these first.** Do not use literal placeholder strings in GraphQL queries.

## Prerequisites

- GitHub CLI (`gh`) authenticated with repo access
- `jq` installed for JSON processing
- `gh pr-enrich` extension installed: `gh extension install bl4ck3lk/gh-pr-enrich`
- For AI enrichment: [Claude CLI](https://claude.ai/code) installed and authenticated

## Quick Start

```bash
# Install the extension (one-time)
gh extension install bl4ck3lk/gh-pr-enrich

# Basic PR analysis
gh pr-enrich 123

# With Claude AI enrichment (analyzes unresolved threads and issue comments)
gh pr-enrich 123 --enrich

# Enrichment with code diffs included in the Claude context
gh pr-enrich 123 --enrich --diff

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
| `install-skill` | Symlink this skill into `~/.claude/skills/` |
| `uninstall-skill` | Remove the skill symlink |
| `resolve <ID...>` | Resolve one or more review threads by GraphQL ID |
| `watch <PR>` | Monitor a PR for new comments (`--interval MIN`, `--enrich`, `--notify`) |
| `address <PR>` | Interactive mode to work through analyzed issues one by one (requires a prior `--enrich` run) |
| `retrospective` | Cross-PR pattern analysis (see "Retrospective Analysis" below) |

### Options

| Option | Description |
|--------|-------------|
| `--json` | Output only JSON (for scripting) |
| `--markdown` | Output only Markdown report |
| `--output-dir DIR` | Custom output directory |
| `--enrich` | Run Claude AI analysis on unresolved threads and issue comments |
| `--diff` | Include code diffs in Claude context (richer analysis) |
| `--sast` | Run a semgrep pre-pass on changed files; findings enter the analysis as deterministic ground truth |
| `--no-code-access` | Deny the analyzer repository access (sandboxed runs). Findings can then only be `plausible` |
| `--model NAME` | Model for the analysis (default: `sonnet`) |
| `--prompt FILE` | Custom prompt file for AI analysis |
| `-h, --help` | Show help |
| `-v, --version` | Show version |

**Recommended for a real bug hunt:** `gh pr-enrich <N> --enrich --diff --sast`. The analyzer reads the repository by default, so it can verify claims rather than paraphrase them.

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `PR_REVIEW_OUTPUT_ROOT` | Override default output directory root |
| `GH_PR_ENRICH_PROMPT` | Path to custom prompt file for Claude analysis |
| `GH_PR_ENRICH_MODEL` | Model for the analysis (default: `sonnet`) |
| `GH_PR_ENRICH_CODE_ACCESS` | `false` disables repository read access |
| `GH_PR_ENRICH_TRUNCATE_CHARS` | Per-comment / per-diff truncation limit (default: 5000) |
| `GH_PR_ENRICH_SEMGREP_CONFIG` | `semgrep --config` value for `--sast` (default: `auto`) |
| `GH_PR_ENRICH_SEMGREP_TIMEOUT` | Seconds allowed for the semgrep pre-pass (default: 180) |
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
| `comment-threads.json` | Thread data with GraphQL IDs and `isResolved` status |
| `checks.json` | CI/CD status information |
| `linked-issues.json` | Issues this PR closes (intent the diff cannot show) |
| `claude-analysis.json` | (if --enrich) Structured AI analysis |
| `claude-analysis.md` | (if --enrich) Human-readable AI report |
| `claude-context.json` | (if --enrich) Exactly what the analyzer was shown, including its `coverage` block |
| `claude-stderr.log` | (if --enrich) Analyzer stderr — read this first when an analysis comes back empty |
| `context-coverage.md` | (if --enrich) Rendered table of what was truncated, dropped or omitted |
| `pr-diff.txt` / `pr-diff.json` | (if --diff) Raw and per-file structured diff |
| `sast-findings.json` | (if --sast) Normalized semgrep findings |

## Analyzing Output

### Reading the Claude Analysis

When using `--enrich`, the AI analysis contains eight sections:

#### 1. Issue Categories

Each finding is verified, categorized, rated and anchored:

```json
{
  "issue_categories": [
    {
      "name": "Retry loop never terminates on 429",
      "category": "logic_error",
      "verdict": "confirmed",
      "confidence": "high",
      "severity": "critical",
      "impact": "severe",
      "likelihood": "likely",
      "severity_rationale": "Upstream 429 keeps attempts at 0, so the loop never exits; happens on any rate-limited request.",
      "description": "The attempt counter resets inside the catch block.",
      "evidence": [
        {"file": "src/retry.js", "line": 42, "detail": "attempts = 0 inside catch, resets the guard"}
      ],
      "thread_ids": ["PRRT_xxx"]
    }
  ]
}
```

**Verdict** — what verification concluded:
- `confirmed` — the defect was traced in the code
- `plausible` — consistent with the visible evidence, but the deciding code was not reachable
- `refuted` — checked and found wrong (also listed in `disputed_comments`)

**Severity is derived, not assigned by category.** It comes from `impact` × `likelihood`:

| | certain | likely | possible | unlikely |
|---|---|---|---|---|
| **severe** | critical | critical | high | medium |
| **moderate** | high | high | medium | low |
| **minor** | medium | low | low | low |

A style comment can be critical and a security comment can be low. `severity_rationale` must name the consequence and the trigger — severity without that is guessing.

**The 16 categories** are fixed: `logic_error`, `boundary_condition`, `concurrency`, `error_handling`, `resource_lifecycle`, `security`, `secrets_exposure`, `data_integrity`, `api_contract`, `performance`, `test_gap`, `observability`, `maintainability`, `documentation`, `build_ci`, `dependency_risk`.

#### 1b. Disputed Comments

Reviewer or bot claims that were checked and found incorrect:

```json
{
  "disputed_comments": [
    {
      "thread_id": "PRRT_yyy",
      "claim": "This leaks the file handle",
      "why_incorrect": "The handle is closed by the defer on line 88.",
      "confidence": "high"
    }
  ]
}
```

**Use these to:** reply to the thread with the reason instead of making a pointless change. Do not resolve a disputed thread unilaterally — reply, then let the reviewer close it.

#### 1c. Category Coverage

One entry per category, so an unswept axis is visible:

```json
{
  "category_coverage": [
    {"category": "concurrency", "verdict": "reviewed_none_found", "note": "No shared mutable state in the diff."},
    {"category": "data_integrity", "verdict": "not_reviewable", "note": "Migration files were not included in the context."}
  ]
}
```

**Use these to:** find where the review is blind. `not_reviewable` is a to-do for you, not a clean bill of health.

#### 2. Systemic Issues

Patterns that appear across multiple comments:

```json
{
  "systemic_issues": [
    {
      "pattern": "Incomplete Error Handling Pattern",
      "evidence": [
        "Thread PRRT_xxx: missing error context",
        "Thread PRRT_yyy: silent failure in catch block"
      ],
      "recommendation": "Create standard error wrapper..."
    }
  ]
}
```

**Use these to:**
- Identify root causes vs symptoms
- Prioritize fixes that address multiple issues
- Improve codebase-wide patterns

#### 3. Adjacent Problems

Related areas that may have similar issues:

```json
{
  "adjacent_problems": [
    {
      "area": "Other API endpoints",
      "risk": "Same error handling pattern may exist",
      "investigation_hint": "Search for similar try/catch blocks..."
    }
  ]
}
```

**Use these to:**
- Proactively find related bugs
- Scope follow-up investigations
- Prevent whack-a-mole debugging

#### 4. Task List

Prioritized actions, each anchored to code and provable:

```json
{
  "task_list": [
    {
      "priority": "critical",
      "task": "Move the attempt counter reset outside the catch block",
      "thread_ids": ["PRRT_xxx"],
      "file": "src/retry.js",
      "line": 42,
      "suggested_fix": "Delete `attempts = 0` from the catch; reset only on success.",
      "verification": "npm test -- retry.test.js"
    }
  ]
}
```

**Use these to:**
- Create a TODO list for addressing feedback
- Prioritize work by severity
- Track which threads each fix addresses
- Run the stated `verification` after each fix — a task is not done until its check passes

Tasks with no single code site use `file: "n/a"` and `line: 0`.

#### 5. Process Improvements

Suggestions to prevent similar issues in future PRs:

```json
{
  "process_improvements": [
    {
      "category": "automation",
      "suggestion": "Add ESLint rule for error handling patterns",
      "rationale": "Multiple comments about inconsistent error handling could be caught automatically",
      "implementation_hint": "Configure eslint-plugin-promise with consistent-return rule"
    }
  ]
}
```

**Categories:**
- `documentation` - README, code comments, ADRs
- `automation` - Linting, CI checks, pre-commit hooks
- `testing` - Unit tests, integration tests, test coverage
- `review_process` - Review checklists, required reviewers
- `tooling` - Development tools, IDE configurations

**Use these to:**
- Systematically prevent recurring issues
- Build institutional knowledge
- Improve team velocity over time

#### 6. PR Template Suggestions

Additions to your PR template that would catch issues earlier:

```json
{
  "pr_template_suggestions": [
    {
      "section": "Testing Checklist",
      "checkbox_or_question": "- [ ] Error handling follows project patterns (see docs/error-handling.md)",
      "why": "3 of 5 issues related to inconsistent error handling"
    }
  ]
}
```

**Use these to:**
- Evolve your PR template based on real feedback patterns
- Shift issue detection left (author catches before reviewer)
- Document team standards incrementally

### Working with Thread IDs

Thread IDs (format: `PRRT_xxx`) are GraphQL identifiers for review threads. Use them to:

**Find specific threads:**
```bash
jq '.data.repository.pullRequest.reviewThreads.nodes[]
    | select(.id == "PRRT_xxx")' comment-threads.json
```

**Get all unresolved threads:**
```bash
jq '[.data.repository.pullRequest.reviewThreads.nodes[]
    | select(.isResolved == false)]' comment-threads.json
```

**Resolve threads programmatically:**
```bash
# Built-in subcommand (accepts one or more IDs)
gh pr-enrich resolve "$THREAD_ID"

# Equivalent raw GraphQL
gh api graphql -f query='mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread { isResolved }
  }
}' -f threadId="$THREAD_ID"
```

### Extracting Actionable Data

**Get high-priority tasks:**
```bash
jq '.task_list | map(select(.priority == "critical" or .priority == "high"))' \
  claude-analysis.json
```

**List all issue categories by severity:**
```bash
jq '.issue_categories | sort_by(.severity) | reverse | .[] | "\(.severity): \(.name)"' \
  claude-analysis.json
```

**Get thread count per category:**
```bash
jq '.issue_categories | map({name, count: (.thread_ids | length)})' \
  claude-analysis.json
```

**Export tasks as markdown checklist:**
```bash
jq -r '.task_list[] | "- [ ] [\(.priority)] \(.task)"' claude-analysis.json
```

## Workflow Examples

### Workflow 1: Comprehensive PR Review

```bash
# 1. Resolve context (current branch's PR; for a specific PR override
#    PR_NUMBER manually as documented in "Resolving Owner, Repo, and PR Number")
OWNER=$(gh repo view --json owner -q '.owner.login')
REPO=$(gh repo view --json name -q '.name')
PR_NUMBER=$(gh pr view --json number -q '.number')

# 2. Fetch and analyze the PR
gh pr-enrich "$PR_NUMBER" --enrich

# 3. Read the analysis
cat .reports/pr-reviews/pr-$PR_NUMBER/claude-analysis.md

# 4. Check systemic issues and adjacent problems
jq '.systemic_issues' .reports/pr-reviews/pr-$PR_NUMBER/claude-analysis.json
jq '.adjacent_problems' .reports/pr-reviews/pr-$PR_NUMBER/claude-analysis.json

# 5. Check for non-thread comments (general PR comments not on code lines)
jq '[.[] | select(.type == "issue_comment")]' \
  .reports/pr-reviews/pr-$PR_NUMBER/all-comments.json

# 6. Work through tasks, reply+resolve threads, verify CI
# (see Required Analysis Workflow steps 3-5)
```

### Workflow 2: Address PR Feedback Systematically

```bash
# 1. Fetch and enrich
gh pr-enrich 123 --enrich

# 2. Review systemic issues and adjacent problems FIRST
jq '.systemic_issues' .reports/pr-reviews/pr-123/claude-analysis.json
jq '.adjacent_problems' .reports/pr-reviews/pr-123/claude-analysis.json

# 3. Create working checklist from critical/high tasks
jq -r '.task_list[]
  | select(.priority == "critical" or .priority == "high")
  | "- [ ] \(.task)"' .reports/pr-reviews/pr-123/claude-analysis.json > todo.md

# 4. Work through each task. After each fix, REPLY first then RESOLVE
#    (see "Resolve Addressed Threads" — Step A reply, Step B resolve).
# Step A: reply with the fix commit
THREAD_ID="PRRT_xxx"
gh api graphql -f query='mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) {
    comment { id }
  }
}' -f threadId="$THREAD_ID" -f body="Fixed in $(git rev-parse --short HEAD) — [brief description of the fix]"

# Step B: then resolve the thread (same variable as Step A; accepts multiple IDs)
gh pr-enrich resolve "$THREAD_ID"

# 5. Final thread audit — verify no unresolved threads were missed
gh api graphql --paginate -F owner="$OWNER" -F repo="$REPO" -F number="$PR_NUMBER" -f query='
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { id isResolved comments(first: 1) { nodes { body } } }
      }
    }
  }
}' | jq -s '[.[].data.repository.pullRequest.reviewThreads.nodes[]
  | select(.isResolved == false)]'

# 6. Verify all CI/CD checks pass
gh pr checks "$PR_NUMBER"
# If any fail: gh run view <RUN_ID> --log-failed
```

### Workflow 3: Investigate Patterns Before Fixing

```bash
# Run analysis
gh pr-enrich 123 --enrich

# Check for systemic issues first
jq '.systemic_issues[] | {pattern, recommendation}' \
  .reports/pr-reviews/pr-123/claude-analysis.json

# Look at adjacent problems to scope investigation
jq '.adjacent_problems[] | {area, investigation_hint}' \
  .reports/pr-reviews/pr-123/claude-analysis.json
```

### Workflow 4: Custom Analysis Focus

Create a security-focused prompt:

```bash
# Create custom prompt
cat > ~/.config/security-pr-prompt.txt << 'EOF'
You are a security engineer analyzing unresolved PR comment threads.

Focus on:
1. Security vulnerabilities (injection, auth bypass, data exposure)
2. Input validation gaps
3. Error handling that leaks information
4. Authentication/authorization issues

Severity ratings:
- critical: Exploitable vulnerabilities
- high: Security gaps requiring immediate attention
- medium: Defense-in-depth improvements
- low: Security best practices

Be specific about attack vectors and remediation steps.
EOF

# Use custom prompt
gh pr-enrich 123 --enrich --prompt ~/.config/security-pr-prompt.txt
```

## Integration with Claude Code

### Addressing PR Comments in Session

When working in a Claude Code session to address PR feedback:

```bash
# 1. Fetch the PR context
gh pr-enrich 123 --enrich

# 2. Read the analysis into context
# Claude can now reference:
# - .reports/pr-reviews/pr-123/claude-analysis.json
# - .reports/pr-reviews/pr-123/comprehensive-report.md
# - .reports/pr-reviews/pr-123/comment-threads.json
```

**Claude MUST follow this sequence (no steps may be skipped):**

1. **Resolve context** - Extract `OWNER`, `REPO`, `PR_NUMBER` from git context (see "Resolving Owner, Repo, and PR Number")
2. **Read systemic_issues first** - Understand the underlying patterns before making any changes
3. **Read adjacent_problems** - Identify related areas that may need the same fixes
4. **Investigate adjacent areas** - Search the codebase for similar issues flagged in adjacent_problems
5. **Check non-thread comments** - Review general PR comments for actionable feedback not captured in review threads
6. **Work through task_list** - Address tasks with full context of patterns and related code
7. **Reply and resolve threads as each task completes** - After fixing each task, reply with the fix commit, then resolve its thread IDs. Track resolved vs remaining threads.
8. **Final thread audit** - After all tasks are done, query the PR for any remaining unresolved threads. Resolve any that were addressed. Leave a reply on any intentionally left open.
9. **Verify all CI/CD checks pass** - Run `gh pr checks "$PR_NUMBER"` and confirm all checks are green. If any fail, investigate and fix before declaring work complete.
10. **Re-request review** - Notify original reviewers that feedback has been addressed.

**Example prompt for Claude:**
> "Read the claude-analysis.json. First summarize the systemic issues and adjacent problems you found. Investigate the adjacent areas mentioned. Check non-thread PR comments for additional feedback. Then address each critical and high priority task in order, applying fixes consistently across all affected areas. After fixing each task, reply with the fix commit and resolve its thread IDs. When all tasks are done, verify no threads were missed, confirm all CI checks pass, and re-request review."

**Anti-patterns to avoid:**
> ~~"Read the claude-analysis.json and address each task in order."~~
This skips the critical analysis steps and leads to incomplete, symptom-focused fixes.

> ~~"Fix all the issues, then I'll resolve the threads myself."~~
This leads to forgotten thread resolutions. Claude MUST resolve threads as it goes.

> ~~"All tasks addressed, work is complete."~~
Never declare complete without verifying: (a) all addressed threads are resolved, (b) all CI checks pass.

## Common Rationalizations

| Excuse | Reality |
|--------|---------|
| "A reviewer raised it, so it's a real bug" | Reviewers see only the diff and bots pattern-match. Check the `verdict` before you change code; `disputed_comments` exists because claims are wrong regularly. |
| "The analysis found nothing in that category, so it's clean" | Check `category_coverage`. `not_reviewable` means unchecked, and it looks exactly like clean in a task list. |
| "The report covers the whole PR" | Check the coverage block. Truncated comments, dropped diffs and omitted files are listed there, and nothing in them was analyzed. |
| "It's only a style comment, so it's low priority" | Severity is impact × likelihood, not category. Read `severity_rationale` — a critical bug can arrive inside a nit. |
| "The task says what to do, that's enough" | If a task has no `file`, `line` and `verification`, you cannot prove the fix worked. Re-derive them before starting. |
| "Adjacent problems were listed, so they were checked" | `checked: false` means the analyzer could not search. That one is yours. |
| "The analysis came back empty, the PR must be clean" | Read `claude-stderr.log`. An empty analysis is usually a failed or timed-out run, not a clean PR. |
| "I'll resolve threads after fixing everything" | You'll forget. Resolve as you go — progress should be visible to reviewers immediately. |
| "CI was passing before my changes" | CI tests your changes against the full suite. Run `gh pr checks` after every push. |
| "I already read the comments" | Reading ≠ systematic analysis. Run `--enrich` and follow the workflow. Systemic issues hide in individually-innocuous comments. |
| "Only 2 threads, I don't need the full workflow" | Systemic issues hide in even 1 thread. The adjacent problems step takes 2 minutes and prevents the next PR getting the same feedback. |
| "Adjacent problems are out of scope" | Adjacent problems prevent the next PR getting the same feedback. 5 minutes of investigation now saves hours of review cycles later. |
| "Tests pass so CI will be fine" | Tests != CI. Linting, type checks, build steps, security scans, and other checks also run. Verify independently. |
| "I'll check CI later" | Later = never. Failed checks block merge and waste reviewer time. Check immediately after pushing. |
| "Thread resolution is the author's job" | Thread resolution is whoever addresses the feedback. If you fixed it, you resolve it. |

**If you catch yourself thinking any of these, STOP. You are about to skip a mandatory step.**

## Red Flags — STOP

- Changing code for a finding whose `verdict` is `refuted`, or that appears in `disputed_comments`
- Treating a `plausible` finding as confirmed without checking the code yourself
- Reporting a category as clean when its coverage verdict is `not_reviewable`
- Concluding "no issues" from an empty analysis without reading `claude-stderr.log`
- Ranking a finding by its category instead of its `severity` / `severity_rationale`
- Marking a task done without running its `verification`
- About to declare work complete without running the completion gate
- Addressing tasks without first reading systemic issues and adjacent problems
- Resolving threads without replying first (silent resolves are dismissive)
- Re-requesting review while CI checks are failing or pending
- Reading stale `.reports/` files to check current thread/CI status
- Skipping non-thread comment check ("they're probably not important")
- Fixing a task without checking if the same pattern exists in adjacent code
- Using placeholder strings (`OWNER`, `REPO`) in GraphQL queries instead of resolved values

**All of these mean: stop, go back to the workflow, and follow it.**

### Stale Data Warning

After making fixes, the local `.reports/` files are **stale snapshots** from when `gh pr-enrich` was run. Do NOT re-read them to check current thread status or CI results. Instead:

- **Thread status:** Use the live GraphQL query (see step 4/6)
- **CI status:** Use `gh pr checks "$PR_NUMBER"` (see step 7)
- **To refresh all data:** Re-run `gh pr-enrich "$PR_NUMBER"` (without `--enrich` to save time if you only need updated thread/check data)

### Handling Non-Thread Comments

General PR comments (not attached to a code line) are NOT tracked as review threads and have no `isResolved` status. They can still contain actionable feedback.

`--enrich` includes these issue comments (including bot/CI reports from github-actions and security scanners) in the analysis context, so their findings appear in `claude-analysis.json`. Superseded bot reposts are collapsed to the newest revision, and the count of dropped duplicates appears in the coverage block. Still check them live at completion — new comments may have arrived after the report was generated.

**Check for them:**
```bash
# List issue-level comments (not part of review threads)
gh api repos/$OWNER/$REPO/issues/$PR_NUMBER/comments \
  --jq '.[] | {id: .id, author: .user.login, body: .body}'
```

**How to handle:**
- Read each non-thread comment for actionable feedback
- If it requires a code change, address it and reply acknowledging the fix
- If it's a question, reply with the answer
- Non-thread comments cannot be "resolved" — replies are the only signal

### Re-Requesting Review

After all tasks are addressed, threads resolved, and CI is green, re-request review from the original reviewers:

```bash
# List who reviewed the PR
gh pr view $PR_NUMBER --json reviews --jq '.reviews[].author.login' | sort -u

# Re-request review
gh pr edit $PR_NUMBER --add-reviewer <REVIEWER_LOGIN>
```

**Do this as the final step.** Re-requesting review before CI passes or threads are resolved wastes reviewer time.

### Combining with TodoWrite

Use the task list to populate Claude's todo tracking:

```bash
# Extract tasks
jq -r '.task_list[] | "\(.priority): \(.task)"' \
  .reports/pr-reviews/pr-123/claude-analysis.json
```

Then ask Claude to add these to the todo list and work through them systematically.

## Completion Gate (MANDATORY)

Before declaring any PR feedback session complete, Claude MUST pass this checklist. No exceptions.

### Thread Resolution Verification

```bash
# Query remaining unresolved threads (assumes $OWNER/$REPO/$PR_NUMBER were resolved earlier)
UNRESOLVED=$(gh api graphql --paginate -F owner="$OWNER" -F repo="$REPO" -F number="$PR_NUMBER" -f query='
query($owner: String!, $repo: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { id isResolved }
      }
    }
  }
}' | jq -s '[.[].data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length')

echo "Unresolved threads remaining: $UNRESOLVED"
```

- If `UNRESOLVED == 0` → pass
- If `UNRESOLVED > 0` → list each one and categorize:
  - **Addressed but forgot to resolve** → resolve now
  - **Intentionally deferred** → reply on thread with rationale
  - **Not yet addressed** → address or explain in PR comment

### CI/CD Checks Verification

```bash
# Verify all checks pass
gh pr checks "$PR_NUMBER"
```

- All checks pass → pass
- Any check fails → diagnose and fix (see step 5 in Required Analysis Workflow)
- Checks still running → wait and re-check

### Non-Thread Comment Check

```bash
# Check for general PR comments that may contain unaddressed feedback
gh api repos/$OWNER/$REPO/issues/$PR_NUMBER/comments \
  --jq '.[] | {author: .user.login, body: .body}' | head -50
```

- Review each comment for actionable items
- Reply to any that were addressed or need a response

### Re-Request Review

```bash
# Only after all gates above pass:
gh pr edit $PR_NUMBER --add-reviewer <REVIEWER_LOGIN>
```

### Completion Summary Template

When finishing a PR feedback session, Claude MUST output a summary in this format:

```
## PR Feedback Session Complete

**Tasks addressed:** X of Y
**Threads resolved:** A of B (C intentionally deferred)
**Non-thread comments reviewed:** N
**CI/CD status:** all passing | X failing (details below)
**Review re-requested from:** [reviewer list] | not yet (reason)

### Resolved threads
- PRRT_xxx — [task description] — fixed in [commit]
- PRRT_yyy — [task description] — fixed in [commit]

### Deferred threads (with rationale)
- PRRT_zzz — [reason for deferral]

### Non-thread comments addressed
- Comment by @reviewer — [summary of response]

### CI/CD details (if any failures)
- [check name] — [status] — [action taken or needed]
```

**Why this gate exists:** PR authors commonly address feedback but forget to resolve threads, don't check CI, skip non-thread comments, or forget to re-request review. This wastes reviewer time and delays merges. The completion gate makes all four impossible to skip.

## Customizing the Analysis Prompt

The prompt is loaded from (in priority order):
1. `--prompt FILE` argument
2. `GH_PR_ENRICH_PROMPT` environment variable
3. `.gh-pr-enrich-prompt.txt` in repo root
4. `default-prompt.txt` bundled with extension

**Prompt file format:**
- Lines starting with `#` are comments (ignored)
- Remaining text becomes the system prompt
- Must work with the JSON schema (issue_categories, systemic_issues, adjacent_problems, task_list)

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

### Claude Analysis Empty

If analysis returns empty arrays:
- Verify Claude CLI is authenticated: `claude --version`
- Check the context file was created: `cat claude-context.json`
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

## Retrospective Analysis

The `retrospective` subcommand analyzes patterns across all PR reports to identify systemic issues and generate actionable insights.

### When to Use Retrospective

- After completing a sprint or milestone
- When noticing recurring PR feedback
- To generate CLAUDE.md additions from lessons learned
- To create team-wide implementation checklists
- Before starting a new feature to review past patterns

### Retrospective Command

```bash
# Basic retrospective
gh pr-enrich retrospective

# Last 30 days with Claude meta-analysis
gh pr-enrich retrospective --since 30d --enrich

# Filter by author
gh pr-enrich retrospective --author alice,bob

# Output formats for integration
gh pr-enrich retrospective --format claude-md    # CLAUDE.md section
gh pr-enrich retrospective --format checklist    # Implementation checklist
gh pr-enrich retrospective --format pr-template  # PR template additions
```

### Retrospective Options

| Option | Description |
|--------|-------------|
| `--since DATE` | Filter PRs from date (ISO 8601 or `30d`, `2w`, `3m`) |
| `--author LOGIN` | Filter by author(s), comma-separated |
| `--reports-dir DIR` | Path to reports directory |
| `--output-dir DIR` | Where to save output |
| `--enrich` | Use Claude for meta-analysis |
| `--min-prs N` | Warn if fewer PRs found |
| `--format TYPE` | Output: `claude-md`, `pr-template`, `checklist` |
| `--json` | Output JSON only |
| `--markdown` | Output Markdown only |

### Retrospective Output

The retrospective generates several files in `.reports/retrospectives/`:

| File | Description |
|------|-------------|
| `retrospective-report.md` | Human-readable summary |
| `retrospective-data.json` | Complete machine-readable data |
| `cross-pr-patterns.json` | Patterns with occurrence counts |
| `hotspots.json` | Components by issue frequency |
| `guiding-questions.json` | Generated checklists |
| `claude-meta-analysis.json` | (if --enrich) Deep analysis |

### Interpreting Retrospective Output

**Cross-PR Patterns**: Issues appearing in multiple PRs indicate systemic problems. High occurrence + high severity = priority fix.

```bash
# Find patterns appearing 3+ times
jq '.cross_pr_patterns[] | select(.occurrences >= 3)' \
  .reports/retrospectives/retrospective-data.json
```

**Hotspots**: Components with many issues need architectural review or better test coverage.

**Guiding Questions**: Use these as pre-implementation checklists to prevent recurring issues.

**Connection to entropy ENFORCEMENT-GAP:** Cross-PR patterns that show monotonic increase (e.g., hardcoded strings: 9 → 11 → 18 across PRs) are ENFORCEMENT-GAP findings — the root cause is a missing lint rule or CI check, not developer negligence. When retrospective reveals growing patterns, recommend the specific enforcement mechanism (pre-commit hook, CI rule, build check) that would prevent new occurrences. See `skills/entropy/references/cross-cutting-anti-patterns.md` Protocol 5 for the full escalation pattern.

### Workflow: Sprint Retrospective

```bash
# 1. Generate retrospective for the sprint
gh pr-enrich retrospective --since 2w --enrich

# 2. Review the report
cat .reports/retrospectives/retrospective-report.md

# 3. Extract CLAUDE.md additions
gh pr-enrich retrospective --since 2w --format claude-md >> .claude/CLAUDE.md

# 4. Update PR template
gh pr-enrich retrospective --since 2w --format pr-template
```

### Workflow: Pre-Implementation Review

```bash
# Before starting a new feature, review past patterns
gh pr-enrich retrospective --format checklist > implementation-checklist.md

# Use the checklist during development
cat implementation-checklist.md
```

## Integration

| Pair with | When | How |
|-----------|------|-----|
| `review-tribunal` | Phase 0 (Scope & Context) | Tribunal invokes `gh pr-enrich --enrich` to gather PR diff, threads, and context for all 6 agents |
| `product-reviewer` | Phase 1 (Intent Discovery) | Product-reviewer uses enriched PR data as the primary source for intent extraction |
| `rationalist-master-reviewer` | Default PR mode | Rationalist invokes `gh pr-enrich` when reviewing the current branch's PR |
| `entropy` | Retrospective → ENFORCEMENT-GAP | Retrospective cross-PR patterns feed directly into entropy's Protocol 5 (Escalation Pattern) for growing violations |
| `post-fix-validation` | After fixing PR feedback | Post-fix-validation Layer 5 (regression suite) should verify CI via `gh pr checks` |
| `root-cause-tracing` | Debugging issues found in analysis | When a systemic issue requires deep investigation |

## Related Skills

- [`github-pr-fetcher`](../github-pr-fetcher/SKILL.md) - Original PR fetching script (less portable)
- [`root-cause-tracing`](../root-cause-tracing/SKILL.md) - For debugging issues found in analysis

## Resources

- **Repository:** https://github.com/bl4ck3lk/gh-pr-enrich
- **Claude CLI:** https://claude.ai/code
- **GitHub CLI:** https://cli.github.com/
