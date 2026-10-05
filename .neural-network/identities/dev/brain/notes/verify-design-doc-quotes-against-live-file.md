---
tags: [docs, tdd, design-docs]
paths: ["**"]
strength: 1
source: "PR#127 MEM-003 retro"
graduated: false
created: 2026-07-18
---

When a design doc quotes current-state text as context ("current exact text: ..."), verify that quote against the LIVE file before trusting it as the basis for an edit -- design docs age faster than the code/prose they describe, and a stale quote can send you editing the wrong location or missing where a related mechanism (e.g. `brain.sh retro-mark`'s actual invocation point) already lives.

Recurrence (MEM-003): the design doc quoted retrospective/SKILL.md's protocol steps, but `retro-mark`'s actual invocation was only implied inside an existing step, not called out as its own numbered action -- required grepping the live file (and brains.md) to find where it really belonged before deciding where the new archive step should fit in the numbered sequence.

For "X must happen after Y in a document" test requirements: do not settle for two separate presence checks (`contains X` + `contains Y`) -- add ONE comparison that would genuinely go red under the wrong ordering (e.g. byte-offset or line-number comparison of the two anchor substrings already used in the presence checks, no extra fixture needed).

Related: [[boundary-test-needs-exact-value-plus-absence-check]] [[verify-ordering-assertions-at-two-levels]]
