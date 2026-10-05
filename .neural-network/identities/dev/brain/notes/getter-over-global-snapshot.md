---
tags: [python, threads, globals, state]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR-close #308 review r2"
graduated: false
created: 2026-07-22
---

When module code holds state derived from a module-level global that another thread REASSIGNS (rather than mutates), a constructor-time snapshot silently decouples forever — pass a zero-arg getter (lambda: GLOBAL) and read it fresh per call. Seen live: engine snapshotted REPOS; rescan_loop reassigns it; /assistant/status would undercount until restart. Applies to any long-lived object built from rebindable globals.

Related: [[lifecycle-changes-need-full-suite]] [[lock-key-canonicalize]]
