---
tags: [merge, gate, process]
paths: ["**"]
strength: 1
source: "retro AST-022 (gate-slip incident)"
graduated: false
created: 2026-07-24
---

Never chain merge/push into the same shell command as the gate check. The gate line must be READ and judged as its own step; the merge is a separate decision issued only after a confirmed PASS. A pipeline that runs "gate && merge" or prints the gate tail alongside an already-executed merge turns the gate into decoration — this fired once: a RED line printed above an already-pushed merge, and only the red being unrelated averted a broken mainline.

Related: [[canonical-merge-locus]] [[clean-main-repro-before-blame]]
