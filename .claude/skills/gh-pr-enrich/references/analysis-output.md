# Reading the Analysis Output

Every field of `claude-analysis.json`, jq recipes for turning it into work,
and worked end-to-end workflows.

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
      "investigation_hint": "Search for similar try/catch blocks...",
      "checked": false
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
