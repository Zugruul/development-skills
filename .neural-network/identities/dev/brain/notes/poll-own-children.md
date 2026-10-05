---
tags: [subprocess, lifecycle, python]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 2
source: "#98 retro — recurrence (stop's poll-for-claimed-effect)"
graduated: false
created: 2026-07-08
---

Liveness checks depend on the RELATIONSHIP to the target: your own direct child needs waitpid/Popen.poll() (kill(pid,0) counts zombies as alive); a detached/foreign process has no zombie state, so kill(pid,0) is correct there. Get it backwards and you miss crashes or lie about shutdowns. Any "does X" lifecycle command must POLL for the effect it claims (bounded), never fire-and-print-success — and the negative-path fixture (a target resisting the action) belongs in red from the start.

Related: [[stderr-suppression-hides-evidence]] [[second-order-after-concurrency-fix]]
