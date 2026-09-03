---
tags: [brain.py, frontmatter, serialization, kb-seed]
paths: ["plugins/spec-workflow/scripts/brain.py", "plugins/spec-workflow/scripts/kb-seed.py"]
strength: 1
source: ""
confidence: direct
learned-from: GL-050 #300
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

brain.py's KEY_ORDER is the frontmatter serialization contract, not a display hint: render_note silently DROPS any frontmatter key not listed there — new metadata fields (e.g. seed-path/seed-commit) must extend KEY_ORDER or they vanish on write with no error. Related idempotence trap: cmd_mint unconditionally bumps last-touched/strength (correct for human mint); any writer needing byte-identical no-ops (a seeder, a sync) must diff candidate content against the existing note itself and skip the write entirely on a true no-op — never route through cmd_mint.

Related: [[hand-write-links-fixtures]]
