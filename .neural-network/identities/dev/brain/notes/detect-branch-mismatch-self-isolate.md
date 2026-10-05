---
tags: [concurrency, agent-orchestration, worktree]
paths: ["**"]
strength: 1
source: "MEM-031 dev retro interview, 2026-07-18"
graduated: false
created: 2026-07-18
---

When a dev agent discovers the shared git clone (no per-agent worktree isolation) has switched branches or shows unexpected dirty state mid-task — most often signaled by a teammate message implying shared-clone activity — treat it as an immediate signal to self-isolate into its own `git worktree add` (keyed off its own branch) rather than attempting to 'fix' or wait out the shared clone. This costs nothing since a worktree shares the object DB with the main clone (no fetch/merge needed once done) and fully avoids corrupting or losing either side's in-flight work. Verify with `git branch --show-current` immediately after any such signal, before touching any file.

Related: [[worktree-isolation-when-multitasking]]
