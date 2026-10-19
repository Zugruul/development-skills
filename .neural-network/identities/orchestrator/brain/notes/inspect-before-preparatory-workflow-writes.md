---
tags: [workflow, preflight, git]
paths: ["plugins/spec-workflow/skills/build-next/SKILL.md", "plugins/spec-workflow/skills/implement-task/SKILL.md"]
strength: 1
source: "Task #285 post-merge dev/reviewer interview"
confidence: direct
graduated: false
created: 2026-10-19
last-touched: 2026-10-19
---

## Guard the first mutation

- Trace startup through preparation, design commits and task registration before placing a preservation check.
- Checking only at registration is too late when an earlier preparation step can already write or commit into a shared checkout.
- Put the shared decision before every relevant entrypoint's first mutation, then test ordering and a real isolated checkout.

Related: [[front-load-exact-mechanics-in-design-docs]] [[worktree-lane-default]]
