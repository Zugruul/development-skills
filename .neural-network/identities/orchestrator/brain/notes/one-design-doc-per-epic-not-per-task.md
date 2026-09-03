---
tags: [design, briefing, epics]
paths: ["docs/design/**"]
strength: 1
source: "session-2026-07-18-19 close-out retrospective"
graduated: false
created: 2026-07-19
---

For a backlog with explicit epics, default to ONE GROWING design doc per epic (each task gets a clearly delimited section within it, e.g. "## CDX-010 -- ...") rather than a fresh one-off design doc per task, whenever tasks in the same epic are likely to share components, adapters, or terminology. Each new section can reference an earlier one directly ("per the earlier section's decision," "this task's adapter already exists from an earlier task in this epic") instead of re-deriving context, and reviewers can verify cross-task consistency (e.g. confirming an adapter file was correctly EXTENDED, not duplicated) by reading the design doc's own account of which task created what.

Recurrence (this session): `docs/design/mem-E0.md` grew across MEM-002/003/004 (all feedback-lifecycle tasks); `docs/design/cdx-E1.md` grew across CDX-010/011 (both capability-language tasks) -- reviewers explicitly cited the doc's own cross-referencing as speeding up review in both cases, and dev agents used it to correctly identify "extend the existing adapter" over "create a new one" without needing that spelled out per-task.

Related: [[front-load-exact-mechanics-in-design-docs]] [[name-reusable-infra-for-followups-explicitly]]
