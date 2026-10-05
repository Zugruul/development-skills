---
tags: [review, design-docs, reuse]
paths: ["**"]
strength: 1
source: "PR#181 CDX-011 retro"
graduated: false
created: 2026-07-19
---

When a task establishes reusable infrastructure a follow-up task is expected to build on (a shared adapter-file split, shared test helper variables, a naming convention), call that out EXPLICITLY in the originating task's own retro/design doc as "infra for follow-ups" -- not just as an incidental byproduct. This lets a later task's design doc name the exact section/variable to extend rather than re-deriving it, and lets a reviewer verify "did this diff extend the pattern or accidentally shadow/duplicate it" as a fast, mechanical check (does the new code reuse the existing variable/helper by NAME, or redefine something with the same shape under a different name).

Recurrence (CDX-010 -> CDX-011): CDX-010 created craft-spec's `references/host-claude.md` adapter and `$CSBODY`/`$CS_ADAPTER` test variables; CDX-011's design doc named the EXACT existing adapter section headers ("## Phase 1", "## Phase 4") the new plan-mode mechanics belonged under, and its implementation was reviewed in one pass because it reused those variables/headers rather than creating parallel ones. A less-explicitly-scoped design doc would have left this to the dev agent's judgment instead of a structural given.

Related: [[front-load-exact-mechanics-in-design-docs]] [[separate-live-repo-state-tests-from-fixtures]]
