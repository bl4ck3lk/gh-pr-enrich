# gh-pr-enrich

A GitHub CLI extension for comprehensive PR analysis with optional Claude AI enrichment.

## Features

- 📋 **Complete PR Details**: Summary, files, labels, assignees, reviewers
- 💬 **All Comments**: Issue comments, review comments, inline code comments
- 🧵 **Thread Tracking**: GraphQL IDs for programmatic thread resolution
- ✅ **CI/CD Status**: Check runs and status information
- 📊 **Statistics**: Comment counts by type/user, recent activity
- 🤖 **Claude AI Analysis** (optional): Categorize issues, identify systemic patterns, generate task lists
- 🧠 **Claude Code Skill**: Included skill teaches Claude how to use and analyze output

## Installation

```bash
gh extension install bl4ck3lk/gh-pr-enrich
```

## Usage

```bash
# Basic PR report
gh pr-enrich 123

# With Claude AI analysis of unresolved comments
gh pr-enrich 123 --enrich

# Output JSON only (for scripting)
gh pr-enrich 123 --json

# Custom output directory
gh pr-enrich 123 --output-dir ./my-reports
```

## Options

| Option | Description |
|--------|-------------|
| `--json` | Output only JSON |
| `--markdown` | Output only Markdown |
| `--output-dir DIR` | Custom output directory |
| `--enrich` | Run Claude AI analysis on unresolved threads |
| `--prompt FILE` | Custom prompt file for Claude analysis |
| `-h, --help` | Show help |
| `-v, --version` | Show version |

## Output Files

When run, the extension creates a directory with:

```
.reports/pr-reviews/pr-123/
├── comprehensive-report.md      # Human-readable summary
├── combined-data.json           # Machine-readable data
├── pr-summary.json              # PR metadata
├── all-comments.json            # All comments combined
├── comment-threads.json         # Thread data with GraphQL IDs
├── checks.json                  # CI/CD status
├── claude-analysis.json         # (if --enrich) AI analysis
└── claude-analysis.md           # (if --enrich) AI report
```

## Claude AI Analysis

When using `--enrich`, Claude analyzes unresolved comment threads and provides:

- **Issue Categories**: Groups issues by type (security, performance, architecture, etc.)
- **Systemic Issues**: Identifies patterns across multiple comments
- **Adjacent Problems**: Suggests related areas to investigate
- **Task List**: Prioritized actions linked to thread IDs

### Requirements for `--enrich`

- [Claude CLI](https://claude.ai/code) must be installed and authenticated

### Customizing the Analysis Prompt

The Claude analysis prompt can be customized. The extension looks for prompts in this order:

1. `--prompt FILE` command-line argument
2. `GH_PR_ENRICH_PROMPT` environment variable
3. `.gh-pr-enrich-prompt.txt` in the current directory
4. `default-prompt.txt` bundled with the extension

To customize, copy the default prompt and modify it:

```bash
# Find extension directory
EXTENSION_DIR=$(dirname $(which gh-pr-enrich 2>/dev/null || echo ~/.local/share/gh/extensions/gh-pr-enrich/gh-pr-enrich))

# Copy default prompt to your repo
cp "$EXTENSION_DIR/default-prompt.txt" .gh-pr-enrich-prompt.txt

# Or set globally via environment
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

## Environment Variables

```bash
# Override default output directory
export PR_REVIEW_OUTPUT_ROOT="./custom-reports"

# Custom prompt file for Claude analysis
export GH_PR_ENRICH_PROMPT="$HOME/.config/gh-pr-enrich-prompt.txt"
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

### Resolve a comment thread

```bash
gh api graphql -f query='mutation {
  resolveReviewThread(input: {threadId: "PRRT_xxx"}) {
    thread { isResolved }
  }
}'
```

## Claude Code Skill

This extension includes a [Claude Code](https://claude.ai/code) skill for enhanced integration. The skill provides Claude with detailed knowledge of how to use this extension and analyze its output.

### Installing the Skill

After installing the extension, symlink the skill to your Claude skills directory:

```bash
# Create skills directory if needed
mkdir -p ~/.claude/skills

# Symlink the skill (updates automatically with extension upgrades)
ln -s ~/.local/share/gh/extensions/gh-pr-enrich/.claude/skills/gh-pr-enrich \
      ~/.claude/skills/gh-pr-enrich
```

### What the Skill Provides

Once installed, Claude Code can:

- **Fetch and analyze PRs** when you ask to "analyze PR #123" or "review PR comments"
- **Interpret analysis results** - understands issue categories, systemic patterns, and task lists
- **Work with thread IDs** - find, filter, and resolve comment threads programmatically
- **Create task lists** from the prioritized AI analysis
- **Customize prompts** for security-focused, performance-focused, or other specialized reviews

### Example Usage in Claude Code

```
> Use gh-pr-enrich to analyze PR 42 and create a todo list from critical issues

> Read the claude-analysis.json and address each high-priority task

> What systemic patterns were found in the PR review?
```

### Skill Location

The skill is located at `.claude/skills/gh-pr-enrich/SKILL.md` in this repository.

## License

MIT
