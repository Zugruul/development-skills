---
tags: [tdd, git]
paths: ["**"]
strength: 1
source: "#97 retro (single-commit slip)"
graduated: false
created: 2026-07-08
---

"Red before green" has TWO bars: verified-during-your-own-workflow and RECONSTRUCTABLE-FROM-GIT-HISTORY by someone who wasn't watching — only the second satisfies the invariant. Commit the failing test the moment it's red, before writing any fix line: it costs nothing in the moment and eliminates the retrofit soft-reset/stash dance entirely. The red commit is part of the definition of done.

Related: [[claims-point-at-diff-lines]] [[batch-red-across-surfaces]]
