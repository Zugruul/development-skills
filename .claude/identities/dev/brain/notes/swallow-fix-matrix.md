---
tags: [shell, errors, testing]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#50 retro"
graduated: false
created: 2026-07-08
---

Hunting a swallowed failure: grep the suspect region for the swallow idioms AS A SET (`2>/dev/null`, `|| true`, `|| :`, unchecked `$(...)` assignment, rc resets) — the worst offenders stack all three. Choose the surface policy by COPYING THE NEAREST SIBLING that already handles its error, not by inventing one. Decision rule: fail-fast when the swallowed value is a PRECONDITION for following logic (an empty read that changes control flow is never warn-level); queue only for known-transient WRITE failures on the replay substrate; warn only for advisory values. Test matrix is the cartesian product (rc: 0/nonzero) x (payload: empty/nonempty) — red-batch every cell the code branches on BEFORE implementing (rc0-empty "fresh repo proceeds" is the cell everyone omits); one fake-binary case arm per cell.

Related: [[red-commit-as-you-go]] [[capture-dont-transcribe]]
