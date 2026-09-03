---
tags: [briefing, schema]
paths: ["plugins/spec-workflow/scripts/*.py"]
strength: 1
source: "PR#231 (MEM-022, #135) -- feedback.py's item ts silently clobbered emit_event's baseline emission-time ts; caught in review, fixed by renaming to itemTs"
graduated: false
created: 2026-07-19
---

When a shared emitter function merges a caller-supplied payload dict over its own baseline fields (e.g. `event.update(obj)` where the baseline already set `ts`/`v`/`repo`), a caller can silently clobber a baseline field just by naming a payload key the same thing -- Python dict.update has no collision warning. When briefing a task that adds a new caller to such a shared emitter, explicitly name which baseline field names are RESERVED (here: v, ts, repo) and require any semantically-different-but-similarly-named value (an item's own timestamp, not the event's emission time) to use a distinct key.

Related: [[check-stray-worktrees-before-branch-ops]]
