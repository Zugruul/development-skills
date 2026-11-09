---
tags: [security, bash, guards]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#561 #564 reviews"
confidence: direct
graduated: false
created: 2026-11-09
last-touched: 2026-11-09
---

Internal shell globals that change control flow are an attack surface: if a script never initialises them, the caller's environment can set them.

## What happened
- Three times in one set, reviewers reproduced a skip of WIP admission or move guards by exporting an internal variable: an audit snapshot path, `_FLUSH_HOLDS_WIP`/`_FLUSH_SNAP`, and `_GUARDS_DONE`.
- Each was a flag meant to be set only by the script's own replay path.

## What to do
- Unset every internal control variable at the script's entry, before sourcing helpers.
- Trust a handoff from a parent only with proof: an exact path inside the lock dir, an ancestor-pid check and a token.
- When reviewing, grep for `${VAR:-}` reads of globals that only internal code sets.
