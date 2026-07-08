---
tags: [review, judgment]
paths: ["**"]
strength: 1
source: "#78 review retro"
graduated: false
created: 2026-07-08
---

"Functionally unnecessary" is not "revert-worthy" by itself: after proving an edit redundant (empirically, not abstractly), check whether it matches EXISTING precedent in the same file — redundant-but-consistent with three prior instances is a nit; redundant-and-novel is a smell. Judging "unnecessary == revert" without the precedent check nearly produced a false blocker on gate-integrity code.

Related: [[read-beyond-the-diff]] [[narrowed-exploit-survives]]
