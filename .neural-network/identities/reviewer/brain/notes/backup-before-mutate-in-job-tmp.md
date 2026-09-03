---
tags: [review, safety, sandbox, shell]
paths: []
strength: 1
source: "Zugruul/development-skills#251"
learned-from: GL-010 review retro
graduated: false
created: 2026-07-21
last-touched: 2026-07-21
---

Stage scratch/backup files under the job's own tmp dir ($CLAUDE_JOB_DIR/tmp), never bare /tmp (sandbox may reject it read-only), and structure backup-then-mutate scripts so the mutation step is provably unreachable if the backup write fails — never rely on incidental statement ordering to protect the tree.
