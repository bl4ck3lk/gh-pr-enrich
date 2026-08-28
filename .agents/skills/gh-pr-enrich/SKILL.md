---
name: gh-pr-enrich
description: Fetch complete GitHub PR context and run evidence-driven analysis with Codex native subagents, optional external Claude, or both.
---

# Codex project adapter

The canonical cross-runtime skill is
[`../../../.claude/skills/gh-pr-enrich/SKILL.md`](../../../.claude/skills/gh-pr-enrich/SKILL.md).

Read that file completely and follow it. In Codex, use current-session native
subagents for the independent analysis lenses and keep the root agent responsible
for evidence verification and final synthesis. Do not launch detached
`codex exec` analyzers.
