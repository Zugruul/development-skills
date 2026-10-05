---
tags: [git]
paths: ["**"]
strength: 1
source: "#96 retro (inverted rebase note from a two-dot diff)"
graduated: false
created: 2026-07-08
---

"What did the other branch do to this file" is a question about THEIR COMMITS, never about the +/- signs of a `git diff A B` — a two-dot diff is symmetric and its "deletions" are equally "things B added that A lacks". Use `git log --oneline HEAD..origin/main -- <path>` (exactly the commits they have that you don't) and `git show <sha> -- <path>` before stating direction in any report.
