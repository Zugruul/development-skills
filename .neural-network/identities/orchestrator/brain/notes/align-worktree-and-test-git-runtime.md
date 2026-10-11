---
tags: [wsl, git, testing]
paths: ["**"]
strength: 1
source: "Local #507/#510 worktree and red-replay validation"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Keep One Git Runtime
- Create and operate a linked worktree with the same Git runtime used by its tests.
- Windows-created absolute gitdir paths are not automatically usable by WSL Git. For WSL tests, create the checkout with WSL Git and keep using it there.
- Do not export `GIT_DIR` or `GIT_WORK_TREE` as a workaround: child tests create their own repositories and can inherit the wrong metadata.

## Preserve Evidence
- Replay red commits in disposable worktrees; keep implementation trees unchanged.
- Keep a running test script immutable, and capture its actual exit status separately from log filtering.
