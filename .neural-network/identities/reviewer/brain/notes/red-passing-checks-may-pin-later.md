---
tags: [review, tdd, tests]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "#90 review retro"
graduated: false
created: 2026-07-08
---

A check that passes at the red commit isn't automatically vacuous — distinguish (a) it never discriminates anything (an exit-code that was already nonzero for unrelated reasons) from (b) it only exercises the NEW code path post-fix (a probe misfire guard that red code never reaches). (a) is decoration to flag; (b) is a legitimate regression pin. Trace which paths the check touches at red vs green before judging.

Related: [[red-commit-worktree-verify]] [[fixture-provenance-check]]
