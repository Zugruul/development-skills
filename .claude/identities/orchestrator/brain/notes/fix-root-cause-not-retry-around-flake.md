---
tags: [process, flakiness, load, infra]
paths: []
strength: 1
source: "#208 -- one targeted fix unblocked #199/#203/#197 simultaneously"
graduated: false
created: 2026-07-16
---

Severe host load (this session saw load average swing 6 to 29) can cause background test-suite runs to get silently killed rather than fail cleanly, and can hard-pin new agent spawns to the wrong worktree regardless of the requested path -- retrying the SAME long-running background command repeatedly under sustained load rarely converges. More effective: (1) switch to foreground execution with an explicit path-verifying command chain when background runs keep getting killed, (2) if a genuine, reproducible root cause is found for a flaky test (not just 'it's flaky'), fix the ROOT CAUSE directly rather than continuing to retry around it -- one well-diagnosed fix (development-skills#208, a hardcoded 3s subprocess-bind timeout) resolved flakiness blocking THREE unrelated in-flight tasks at once.
