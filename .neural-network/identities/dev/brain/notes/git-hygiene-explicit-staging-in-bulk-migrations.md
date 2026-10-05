---
tags: [git, tdd, worktree]
paths: ["plugins/spec-workflow/scripts/preflight.sh"]
strength: 1
source: "task #174 (CDX-002)"
graduated: false
created: 2026-07-16
---

On a mechanical bulk migration (many files, one repeated substitution), stage by explicit path -- `git add plugins/*/skills/*/SKILL.md ...` -- never `git add -A`, and eyeball `git status` for unrelated content before committing or reporting done.

Why: during #174 (CDX-002, migrating 26 SKILL.md files off `${CLAUDE_PLUGIN_ROOT}`), an unrelated regression (a revert of the --model flag-swallowing guard in peer-review.sh/run.sh) appeared uncommitted in the shared worktree -- never opened or edited by this task's own work. Path-scoped staging kept it out of the commit; a blind `git add -A` would have shipped it silently.

How to apply: whenever staging a bulk/mechanical change, prefer explicit path globs over `-A`/`.`, and run `git status` immediately before the final commit to confirm the diff matches exactly what you intended to touch -- especially in a worktree that could have stray or concurrent state.
