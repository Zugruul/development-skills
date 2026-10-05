---
tags: [merge, concurrency, git]
paths: ["**"]
strength: 1
source: "retro AST-022 (upstream races)"
graduated: false
created: 2026-07-24
---

When another session pushes directly to the mainline mid-iteration: (1) a red gate on a task whose diff does not touch the failing surface is likely INHERITED — attribute failures to sections before assigning blame; (2) expect push races — a rejected non-fast-forward after local branch surgery can orphan commits, so recover via reflog and transplant by cherry-pick onto the fresh tip, pushing by SHA; (3) upstream direct pushes that bypassed the gate are the first suspects for any new unexplained red.

Related: [[gate-verdict-before-merge]] [[canonical-merge-locus]]
