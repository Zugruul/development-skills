---
tags: [git, pr, merge, stacking]
paths: ["**"]
strength: 1
source: "retro 2026-07-21 GL epic E0"
graduated: false
created: 2026-07-21
---

When merging a stacked PR chain with squash merges: retarget each child PR's base to main BEFORE deleting the parent branch. GitHub CLOSES (unrecoverably — reopen is impossible once the base ref is gone) any PR whose base branch is deleted; the only recovery is a replacement PR, losing review history linkage. Rebase each child `--onto main <old-parent-tip>` so squashed parent content isn't re-applied.

Related: [[serial-delivery-prevents-stack-debt]]
