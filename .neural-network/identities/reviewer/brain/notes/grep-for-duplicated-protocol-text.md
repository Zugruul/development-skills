---
tags: [review, docs, consistency]
paths: ["plugins/spec-workflow/skills/**"]
strength: 1
source: "PR#127 MEM-003 retro"
graduated: false
created: 2026-07-18
---

When reviewing a docs-only/protocol-text diff (SKILL.md, a shared protocol description), the acceptance bar is different but not lower than application code. Protocol text tends to be COPY-PASTED across multiple entry points that describe the same workflow (e.g. a build-next SKILL.md step delegating to a shared reference vs. a sibling SKILL.md duplicating the same instructions inline) -- when a diff fixes staleness at one site, that is a SIGNAL to grep the repo for other sites carrying the same duplicated text, which may share the identical staleness and get silently missed by a diff scoped to only the named files in the task.

Recurrence (MEM-003 review): the spec text named only "retrospective + build-next docs," but implement-task/SKILL.md turned out to duplicate build-next's feedback-routing paragraph inline rather than delegating to it -- found only by checking whether other entry points repeat the same protocol text, not by reading the spec's literal file list.

Also: read the edited file's FULL section/numbered-sequence (not just the diff hunk) to confirm a renumbering or insertion didn't strand a step or break a cross-reference elsewhere in the SAME file -- a numbered protocol step is a literal ordering contract for whoever executes it later, so getting the sequence right matters as much as control flow in code.

Related: [[audit-new-path-parity-before-writing]]
