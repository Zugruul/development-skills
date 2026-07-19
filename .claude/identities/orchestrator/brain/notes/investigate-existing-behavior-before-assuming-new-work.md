---
tags: [design-docs, briefing]
paths: ["docs/design/*.md"]
strength: 1
source: "CDX-014 (#184) -- design doc investigation found 2/3 sub-requirements already satisfied, saved the dev agent from reimplementing correct behavior"
graduated: false
created: 2026-07-19
---

Before assuming a spec requirement needs new code, INVESTIGATE whether the codebase already satisfies it -- 2 of CDX-014's 3 sub-requirements (ui-options resume-link omission, neural-view's absent-jobs-dir handling) turned out to already be correctly implemented, and the right move was a pinning/confirming test, not a reimplementation. Writing the design doc's investigation section FIRST (read the actual current code/prose, don't assume from the spec text alone) kept the dev agent from wastefully rebuilding already-correct behavior, and made the PR's scope honest ("2 already-correct, 1 genuinely new") instead of implying everything was new work.

Related: [[old-path-repo-wide-sweep]]
