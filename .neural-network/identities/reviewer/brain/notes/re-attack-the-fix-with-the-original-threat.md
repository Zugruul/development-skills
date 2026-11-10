---
tags: [review, security, regression, parsing]
paths: ["plugins/spec-workflow/scripts/task_state.py"]
strength: 1
source: "Zugruul/development-skills#571"
confidence: direct
graduated: false
created: 2026-11-10
last-touched: 2026-11-10
---

# Re-attack each fix with the original threat model, not just the reported case

In #571 round 1 a parsing nit (a quoted "(no comments)" line truncated the body) was fixed by reordering checks. That reorder let any commenter, including untrusted ones, inject TODOs through a crafted last comment. Only a round-2 reviewer who replayed untrusted comment input against the fix caught it.

- When a fix changes parsing or matching order, list which inputs are attacker-controlled (comments, issue bodies, PR text) and run them against the new code.
- A nit fix can open a hole the original code did not have; compare the fix's behaviour with the pre-fix code on hostile inputs.
