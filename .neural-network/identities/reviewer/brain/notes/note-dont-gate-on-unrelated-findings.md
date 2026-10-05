---
tags: [review, scope, process]
paths: ["**"]
strength: 1
source: "PR#127 MEM-003 retro"
graduated: false
created: 2026-07-18
---

When a review turns up a real, unrelated pre-existing defect (a dangling cross-reference, stale numbering) that the current diff did not introduce and is not required to fix, note it explicitly in the review report as a flagged follow-up -- but do NOT gate approval on it. Staying silent loses a legitimate finding; gating blocks a correct diff for a defect it neither introduced nor can reasonably be expected to fix in its own scope. "Diff-scoped blocking, session-scoped noting" keeps review focused on what the diff actually owns while still surfacing drift for someone to pick up later (a backlog item during retro/feedback triage, typically).

Recurrence (MEM-003 review): found an unrelated dangling "step 6's report" reference in build-next/SKILL.md (line 26, untouched by this diff, from a PRIOR renumbering) -- flagged it in the report, approved the diff anyway, orchestrator filed it as a follow-up backlog item.
