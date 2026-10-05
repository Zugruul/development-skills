---
tags: [scope, tdd, discipline]
paths: ["**"]
strength: 1
source: "PR#128 MEM-004 retro"
graduated: false
created: 2026-07-18
---

When a task brief explicitly names something as out of scope AND names the specific future task that owns it (not just "leave it" but "leave it, task Y owns it"), treat that as a hard scope boundary, not a suggestion -- even when fixing it would be trivial while already touching the adjacent file. Fixing it anyway creates rebase/attribution confusion for whoever picks up the named future task, and the task's own DoD is checked against its stated acceptance criteria, not against "did I also leave things tidier than I found them."

Recurrence (MEM-004): a design doc named exactly the tempting scope-creep move (deduplicating pre-existing duplicate `.gitignore` lines) and named the exact future task that owns it (MEM-012) BEFORE the file was even opened -- removed any live moment of temptation, just a checklist to confirm against.

Related: [[audit-new-path-parity-before-writing]]
