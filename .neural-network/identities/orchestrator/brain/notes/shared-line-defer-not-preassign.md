---
tags: [concurrency, orchestration]
paths: []
strength: 1
source: ""
learned-from: loop-feedback 2026-07-07 task-20
graduated: false
created: 2026-07-07
---

Pre-assigning distinct values to parallel lanes (versions, migration ids) removes VALUE collisions but not TEXTUAL conflicts when every lane edits the SAME line from a common base — the second merge still rebases that one line. For a single shared line (e.g. the plugin version), defer the bump to ONE post-merge step instead. Pre-assignment only avoids rebase when lanes write different locations. Refines [[preassign-shared-monotonic-in-lanes]].
