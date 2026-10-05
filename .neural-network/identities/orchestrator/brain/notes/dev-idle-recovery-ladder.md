---
tags: [delegation, process]
paths: ["plugins/spec-workflow/skills/build-next"]
strength: 1
source: "feedback 2026-08-01 item 0, four dev lanes"
confidence: direct
graduated: false
created: 2026-08-01
last-touched: 2026-08-01
---

A dev subagent going idle is a checkpoint, not a failure: first verify the branch state yourself (commits, tree, gate), then nudge ONCE with the exact remaining steps; if the work is complete but unlanded after that, gate and commit it yourself under the dev identity with the circumstances noted in the commit body. Never loop on nudges — two idles with no progress means take over mechanically. See [[retroactive-records-honesty]] for the sibling rule when history, not the agent, is what's incomplete.
