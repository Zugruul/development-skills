---
tags: [concurrency, lock, network, task-state]
paths: ["plugins/spec-workflow/scripts/task_state.py"]
strength: 1
source: "Zugruul/development-skills#571"
confidence: direct
graduated: false
created: 2026-11-10
last-touched: 2026-11-10
---

# Never hold a shared lock across a network call

#571 first fetched the issue (gh api, 60 s timeout) while holding the repo-wide task-state lock, so every agent's task-state write on any task waited on the network (reproduced: 4.5 s for an unrelated write behind a 5 s stub).

- Read under the lock, release it, do the network call, then re-lock, re-read, and write only if the state still needs it.
- Accept the rare duplicate fetch over blocking every writer.
