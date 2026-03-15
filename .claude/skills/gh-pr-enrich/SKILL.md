---
name: gh-pr-enrich
description: Fetch comprehensive PR details and optionally run Claude AI analysis on unresolved comment threads. Use when reviewing PRs, addressing PR feedback, investigating review comments, or when users request PR analysis. Produces structured JSON and Markdown reports with issue categorization, systemic patterns, and prioritized task lists. Enforces mandatory thread resolution after addressing feedback and CI/CD check verification before declaring work complete.
---

# gh-pr-enrich Skill

Comprehensive PR analysis using the `gh pr-enrich` GitHub CLI extension. Fetches complete PR context (comments, threads, checks, files) and optionally enriches with Claude AI analysis to categorize issues, identify patterns, and generate actionable task lists.

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
```

**Why this matters:** PR reviewers see only the changed code. Adjacent problems highlight areas with similar issues that weren't in the PR diff. Investigating these prevents:
- Incomplete fixes that miss related code
- Future PRs with the same feedback
- Whack-a-mole debugging cycles

### 3. Then Address Tasks in Priority Order

Only after completing steps 1-2 should you work through the `task_list`. Your understanding of systemic issues and adjacent problems should inform how you implement each fix.

**DO NOT** skip to the task list without reviewing systemic issues and adjacent problems first.

### 4. Resolve Addressed Threads (REQUIRED)

After fixing each task, you MUST reply to and resolve the corresponding review threads immediately. Do NOT batch this to the end — resolve threads as you go so progress is visible to reviewers.

**Reply first, then resolve.** Reviewers expect acknowledgment before resolution. A silent resolve feels dismissive and makes it hard to verify the fix.

```bash
# Step A: Reply to the thread with what you did
gh api graphql -f query='mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) {
    comment { id }
  }
}' -f threadId="PRRT_xxx" -f body="Fixed in $(git rev-parse --short HEAD) — [brief description of the fix]"

# Step B: Then resolve the thread
gh api graphql -f query='mutation {
  resolveReviewThread(input: {threadId: "PRRT_xxx"}) {
    thread { isResolved }
  }
}'
```

**After all tasks are complete**, verify no threads were missed:

```bash
# Re-fetch thread status and check for any still-unresolved threads
gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes { id isResolved }
      }
    }
  }
}' -f owner=OWNER -f repo=REPO -F number=PR_NUMBER \
  | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)]'
```

If any threads remain unresolved, investigate whether they were:
- **Addressed but not resolved** — resolve them now
- **Intentionally left open** — leave a reply explaining why (e.g., "Will address in follow-up PR #X")
- **Out of scope** — leave a reply stating the rationale

**DO NOT** declare work complete while addressed threads remain unresolved. Unresolved threads block PR approval and signal to reviewers that feedback was ignored.

### 5. Verify CI/CD Checks Pass (REQUIRED)

After all fixes are committed and pushed, you MUST verify that all GitHub Actions and status checks pass. Do NOT assume your changes didn't break CI.

```bash
# Check current status of all checks on the PR
gh pr checks <PR_NUMBER>
```

**Interpret the results:**
- All checks pass → proceed to notify reviewers
- Any check fails → investigate and fix before declaring work complete
- Checks pending → wait and re-check (use `gh pr checks <PR_NUMBER> --watch` or poll)

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

# With Claude AI enrichment (analyzes unresolved threads)
gh pr-enrich 123 --enrich

# JSON output for scripting
gh pr-enrich 123 --json
```

## Command Reference

### Syntax

```bash
gh pr-enrich <PR_NUMBER> [OPTIONS]
```

### Options

| Option | Description |
|--------|-------------|
| `--json` | Output only JSON (for scripting) |
| `--markdown` | Output only Markdown report |
| `--output-dir DIR` | Custom output directory |
| `--enrich` | Run Claude AI analysis on unresolved threads |
| `--prompt FILE` | Custom prompt file for AI analysis |
| `-h, --help` | Show help |
| `-v, --version` | Show version |

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `PR_REVIEW_OUTPUT_ROOT` | Override default output directory root |
| `GH_PR_ENRICH_PROMPT` | Path to custom prompt file for Claude analysis |

## Output Files

Default location: `.reports/pr-reviews/pr-<NUMBER>/`

| File | Description |
|------|-------------|
| `comprehensive-report.md` | Human-readable summary of PR |
| `combined-data.json` | Complete machine-readable data |
| `pr-summary.json` | PR metadata (title, body, author, files) |
| `all-comments.json` | All comments combined |
| `comment-threads.json` | Thread data with GraphQL IDs and `isResolved` status |
| `checks.json` | CI/CD status information |
| `claude-analysis.json` | (if --enrich) Structured AI analysis |
| `claude-analysis.md` | (if --enrich) Human-readable AI report |

## Analyzing Output

### Reading the Claude Analysis

When using `--enrich`, the AI analysis contains six key sections:

#### 1. Issue Categories

Groups unresolved comments by type with severity ratings:

```json
{
  "issue_categories": [
    {
      "name": "Missing Request Correlation IDs",
      "severity": "high",
      "description": "Multiple Sentry captures lack request_id...",
      "thread_ids": ["PRRT_xxx", "PRRT_yyy"]
    }
  ]
}
```

**Severity levels:**
- `critical` - Security vulnerabilities, data loss, breaking changes
- `high` - Bugs, performance issues, architectural problems
- `medium` - Code quality, maintainability, missing tests
- `low` - Style, documentation, minor improvements

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

Prioritized actions linked to thread IDs:

```json
{
  "task_list": [
    {
      "priority": "critical",
      "task": "Add request_id to all captureException calls",
      "thread_ids": ["PRRT_xxx", "PRRT_yyy"]
    }
  ]
}
```

**Use these to:**
- Create TODO list for addressing feedback
- Prioritize work by severity
- Track which threads each fix addresses

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

**Resolve a thread programmatically:**
```bash
gh api graphql -f query='mutation {
  resolveReviewThread(input: {threadId: "PRRT_xxx"}) {
    thread { isResolved }
  }
}'
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
# 1. Resolve context
OWNER=$(gh repo view --json owner -q '.owner.login')
REPO=$(gh repo view --json name -q '.name')
PR_NUMBER=123

# 2. Fetch and analyze the PR
gh pr-enrich $PR_NUMBER --enrich

# 3. Read the analysis
cat .reports/pr-reviews/pr-$PR_NUMBER/claude-analysis.md

# 4. Check systemic issues and adjacent problems
jq '.systemic_issues' .reports/pr-reviews/pr-$PR_NUMBER/claude-analysis.json
jq '.adjacent_problems' .reports/pr-reviews/pr-$PR_NUMBER/claude-analysis.json

# 5. Check for non-thread comments (general PR comments not on code lines)
jq '[.[] | select(.pull_request_review_id == null)]' \
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

# 4. Work through each task, resolving threads IMMEDIATELY after each fix
gh api graphql -f query='mutation {
  resolveReviewThread(input: {threadId: "PRRT_xxx"}) {
    thread { isResolved }
  }
}'

# 5. Final thread audit — verify no unresolved threads were missed
gh api graphql -f query='
query { repository(owner: "OWNER", name: "REPO") {
  pullRequest(number: 123) {
    reviewThreads(first: 100) {
      nodes { id isResolved comments(first: 1) { nodes { body } } }
    }
  }
}}' | jq '[.data.repository.pullRequest.reviewThreads.nodes[]
  | select(.isResolved == false)]'

# 6. Verify all CI/CD checks pass
gh pr checks 123
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
9. **Verify all CI/CD checks pass** - Run `gh pr checks <PR_NUMBER>` and confirm all checks are green. If any fail, investigate and fix before declaring work complete.
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

### Stale Data Warning

After making fixes, the local `.reports/` files are **stale snapshots** from when `gh pr-enrich` was run. Do NOT re-read them to check current thread status or CI results. Instead:

- **Thread status:** Use the live GraphQL query (see step 4/6)
- **CI status:** Use `gh pr checks <PR_NUMBER>` (see step 7)
- **To refresh all data:** Re-run `gh pr-enrich <PR_NUMBER>` (without `--enrich` to save time if you only need updated thread/check data)

### Handling Non-Thread Comments

General PR comments (not attached to a code line) are NOT tracked as review threads and have no `isResolved` status. They can still contain actionable feedback.

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
# Query remaining unresolved threads
UNRESOLVED=$(gh api graphql -f query='
query($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 100) {
        nodes { id isResolved }
      }
    }
  }
}' -f owner=OWNER -f repo=REPO -F number=PR_NUMBER \
  | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length')

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
gh pr checks <PR_NUMBER>
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

### No Unresolved Threads

If `--enrich` reports "No unresolved threads found":
- All review threads may already be resolved
- Check `comment-threads.json` to verify thread status
- Issue comments (not on code lines) aren't tracked as threads

### Claude Analysis Empty

If analysis returns empty arrays:
- Verify Claude CLI is authenticated: `claude --version`
- Check the context file was created: `cat claude-context.json`
- Try with a custom, simpler prompt to debug

### Thread Resolution Fails

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

## Related Skills

- [`github-pr-fetcher`](../github-pr-fetcher/SKILL.md) - Original PR fetching script (less portable)
- [`root-cause-tracing`](../root-cause-tracing/SKILL.md) - For debugging issues found in analysis

## Resources

- **Repository:** https://github.com/bl4ck3lk/gh-pr-enrich
- **Claude CLI:** https://claude.ai/code
- **GitHub CLI:** https://cli.github.com/
