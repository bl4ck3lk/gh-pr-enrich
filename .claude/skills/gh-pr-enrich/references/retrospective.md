# Retrospective Analysis

Cross-PR pattern analysis: when to run it, its options, and how to read what
it produces.

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

# Last 30 days with external Claude meta-analysis. Aggregated reports may
# contain private data, so disclosure authorization is always explicit.
gh pr-enrich retrospective --since 30d --enrich --allow-external

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
| `--allow-external` | Authorize sending aggregated report data to external Claude |
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
gh pr-enrich retrospective --since 2w --enrich --allow-external

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
