---
tags: [design, portability, detection]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#67 retro"
graduated: false
created: 2026-07-08
---

For "detect X without heavy deps": decide UP FRONT which check is load-bearing (must degrade to pure stdlib) vs optional enrichment (may silently return None without the external tool), and write the split into the docstring immediately. Corollaries: lsof's COMMAND column truncates — full argv needs ps -o command=; before rewording any error message, grep the test suite for substring checks against the OLD wording.

Related: [[unassumed-full-pipeline-repro]]
