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
2. **Split findings by verdict** - Separate `confirmed` from `plausible`, and read `disputed_comments`. Refuted claims are replied to, never "fixed".
3. **Check coverage** - Note every `not_reviewable` category and every truncated input; those are the parts of the PR nobody reviewed.
4. **Read systemic_issues** - Understand the underlying patterns before making any changes
5. **Read adjacent_problems** - Identify related areas that may need the same fixes
6. **Investigate adjacent areas** - Search the codebase for the areas marked `checked: false`
7. **Check non-thread comments** - Review general PR comments for actionable feedback not captured in review threads
8. **Verify each `plausible` finding** - Read the cited code before changing it; promote it to a fix or move it to a dispute
9. **Work through task_list** - Address tasks with full context of patterns and related code, and run each task's `verification`
10. **Reply and resolve threads as each task completes** - After fixing each task, reply with the fix commit, then resolve its thread IDs. Track resolved vs remaining threads.
11. **Final thread audit** - After all tasks are done, query the PR for any remaining unresolved threads. Resolve any that were addressed. Leave a reply on any intentionally left open.
12. **Verify all CI/CD checks pass** - Run `gh pr checks "$PR_NUMBER"` and confirm all checks are green. If any fail, investigate and fix before declaring work complete.
13. **Re-request review** - Notify original reviewers that feedback has been addressed.

**Example prompt for Claude:**
> "Read the claude-analysis.json. Start by listing which findings are confirmed, which are only plausible, and which reviewer claims were disputed — then tell me which categories came back not_reviewable. Investigate the adjacent areas marked checked:false. Check non-thread PR comments for additional feedback. Verify each plausible finding against the code before changing anything. Then address each critical and high priority task in order, running each task's stated verification. After fixing each task, reply with the fix commit and resolve its thread IDs. For disputed claims, reply with the reason instead of changing code. When all tasks are done, verify no threads were missed, confirm all CI checks pass, and re-request review."

**Anti-patterns to avoid:**
> ~~"Read the claude-analysis.json and address each task in order."~~
This skips the critical analysis steps and leads to incomplete, symptom-focused fixes.

> ~~"The analysis found 6 issues, I'll fix all 6."~~
Some of those may be refuted claims or unverified guesses. Read the verdicts first.

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

**Tasks addressed:** X of Y (each verified with its stated verification step)
**Threads resolved:** A of B (C intentionally deferred)
**Claims disputed:** D (replied with reasoning, not "fixed")
**Categories not reviewable:** [list, or none] — these were not checked by anyone
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

## Reference Files

Read these when you need them; the workflow above does not depend on them.

| File | Contents |
|------|----------|
| [`references/command-reference.md`](references/command-reference.md) | Syntax, subcommands, options, environment variables, output files, prompt customization, troubleshooting |
| [`references/analysis-output.md`](references/analysis-output.md) | Every field of `claude-analysis.json`, jq recipes, worked workflows |
| [`references/retrospective.md`](references/retrospective.md) | Cross-PR retrospective analysis |

## Integration

| Pair with | When | How |
|-----------|------|-----|
| `xray` | A PR needs more depth than one analysis pass | `xray` fans out specialist reviewers and verifies findings adversarially. Use this skill for the fetch, the single verification pass, thread resolution and the completion gate; use `xray` when you want many independent lenses over the same PR |
| `semgrep-scanning` | Before the analysis | `--sast` already runs semgrep over changed files; use `semgrep-scanning` directly for a whole-repository scan or custom rule authoring |
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
