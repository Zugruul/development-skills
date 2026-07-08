---
tags: [parsing, tests, symbols]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#86 retro"
graduated: false
created: 2026-07-08
---

When hand-parsing source structure: (a) a naive character counter (.count("{")) is never correct for real source — strings/comments contain unbalanced delimiters as the COMMON case; write the quote/comment-aware version and its adversarial fixtures red-first, not as round-2 additions; (b) AST metadata nodes (decorators, annotations) attach OUTSIDE the naive [lineno, end] span — check attachment before trusting spans; (c) "the line after a deletion" anchors to the WRONG scope when the deletion ends the enclosing scope — resolve both boundaries from the start. Your own fixtures being polite to your own implementation is the tell.

Related: [[exclude-before-scan]] [[self-scan-first-class]]
