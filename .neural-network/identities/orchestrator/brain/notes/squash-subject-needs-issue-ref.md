---
tags: [audit, git, merge]
paths: ["**"]
strength: 2
source: "PR#237 board audit, repeated mistake"
graduated: false
created: 2026-07-18
---

board.sh audit's commit-scan only checks the commit SUBJECT line for a #N reference, not the body -- a squash-merge subject like "fix(237): guard-brain-access.sh..." with only "(237)" (no hash) in the subject still counts as a discrepancy. Always put (#N) directly in the squash-merge commit's SUBJECT line. Recurrence (#237): repeated this exact mistake because I didn't recall the orchestrator brain BEFORE writing the squash commit message -- recall orchestrator lessons before any squash-merge commit, not just before mint/design work.
