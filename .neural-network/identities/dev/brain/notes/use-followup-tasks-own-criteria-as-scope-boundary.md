---
tags: [scope, tdd, refactoring]
paths: []
strength: 1
source: "task #129 (MEM-010)"
graduated: false
created: 2026-07-16
---

When a task replaces a duplicated list with a single source of truth, and a related but distinct concern (managed-block writing, drift detection, idempotency) is already scoped to a separate, not-yet-started follow-up task, use that follow-up's own stated acceptance criteria as the boundary -- don't guess where to stop, read what it explicitly claims.

Why: #129 (MEM-010) needed to eliminate one duplicate path list without building MEM-011's gitignore-sync.sh (managed blocks, idempotency, track-path warnings) early -- confirmed correct by checking that MEM-011's own acceptance criteria explicitly owns those exact concerns, and by noting the OLD code had the same non-idempotency MEM-010 was accused of introducing (so it wasn't actually a new gap). A second correct call in the same task: tree-state.sh's own separate fingerprint-exclusion list was deliberately left decoupled from the new manifest, since it answers a different question (what to exclude from a gate fingerprint) than the manifest answers (what to gitignore) -- coupling them would have silently changed gate behavior.

How to apply: before absorbing adjacent-looking work into a task, check whether a sibling task already owns it (read its acceptance criteria, not just its title) and whether the current behavior is actually regressing or just staying as-is. Two things that look similar (a related list, a related concern) are not automatically the same scope.
