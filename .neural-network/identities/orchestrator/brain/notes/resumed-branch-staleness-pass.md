---
tags: [resume, rebase, testing]
paths: ["**"]
strength: 1
source: "retro MEM-030 (resume)"
graduated: false
created: 2026-07-23
---

Resuming an old branch needs a staleness pass beyond the rebase, in BOTH directions: (1) its negative assertions may pin a world that mainline legitimately moved past — re-read every "must NOT contain" against current behavior; (2) its own feature may invalidate machine/global state that OTHER suites assume (an installer makes "not installed" unassumable). Run the FULL suite, not just the branch's section, before declaring the resume done — both failures here only surfaced at full-gate time.

Related: [[search-branches-before-reimplementing]] [[clean-main-repro-before-blame]]
