---
tags: [process, auto-mode, review-flow]
paths: []
strength: 1
source: "#201 follow-up fix, first attempt blocked by classifier, redone via dev-prv004b + reviewer-201b"
graduated: false
created: 2026-07-16
---

A direct orchestrator commit+push to main -- even a small, well-tested fix -- can get blocked by the auto-mode classifier if it bypasses the worktree->dev-agent->independent-reviewer flow the session already established for that class of change (peer-review plugin code, in this case). When blocked: don't work around it, reset the local-only unpushed state cleanly (git reset --hard origin/main after saving any real diff), redo the same fix through a proper worktree + spawned dev agent + independent reviewer. Small chore/config commits (e.g. enabling a plugin, filing board issues) were NOT blocked -- the boundary is specifically substantive code changes to the plugin under active TDD discipline.
