---
tags: [config, migration, debugging]
paths: ["**"]
strength: 3
source: "PR#242 (#234) -- adding a new precondition to a widely-used mutation (board.sh move to In progress) required sweeping the whole tests/ dir for every prior caller; found 4 pre-existing fixture files needing the same fix"
graduated: true
created: 2026-07-07
---

When a value/pattern changes (config default, error-message shape, a buggy raycast target), grep the WHOLE repo for the old literal before writing tests — the second bug instance (dblclick guard's copy of the same line) only surfaced via a deliberate sweep. Pin with a check_absent on the OLD pattern (catches all instances at once), not just a check for the new one.

Related: [[hermetic-tmpdir-per-guard-case]] [[enumerate-state-writers]]
