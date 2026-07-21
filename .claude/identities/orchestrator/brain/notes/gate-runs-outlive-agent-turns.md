---
tags: [gate, subprocess, orchestration]
paths: ["plugins/spec-workflow/scripts/gate.sh"]
strength: 1
source: "retro 2026-07-21 GL epic E0"
graduated: false
created: 2026-07-21
---

The recorded gate run outlives a subagent's tool-call timeout. Working pattern: the dev launches gate.sh via nohup with a log under the job tmp dir and goes idle; the ORCHESTRATOR watches for process exit with a backgrounded waiter (pgrep loop on the worktree-scoped gate path) and nudges the dev to continue when the pass is recorded. Never let an idle dev be mistaken for a stalled dev — check the worktree's commits and gate process first.
