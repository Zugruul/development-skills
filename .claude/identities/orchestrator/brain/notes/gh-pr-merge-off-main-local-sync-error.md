---
tags: [git, process, merge]
paths: []
strength: 1
source: "PR#216/#214 merges, live-encountered"
graduated: false
created: 2026-07-18
---

`gh pr merge --delete-branch` performs the actual GitHub merge via the API first, then tries local bookkeeping (fast-forwarding a local branch, deleting the remote branch). If your working tree is checked out to a branch other than the PR's base (e.g. still on an unrelated feature branch), that local-sync step can fail with a scary-looking "Your local changes... would be overwritten" / "Cannot fast-forward" error -- but the merge itself already succeeded. Don't treat that error as a failed merge: verify with `gh pr view N --json state,mergedAt` before retrying or panicking. Better: `git switch <mainBranch>` before calling `gh pr merge` to avoid the spurious error entirely.
