---
tags: [testing, background-tasks]
paths: ["**"]
strength: 2
source: "PR#225 (MEM-013, #132) -- applied successfully this time (dev-mem013 waited properly), no false-failure report"
graduated: false
created: 2026-07-19
---

When you run a slow command in the background and redirect its output to a log file, don't read that file early and treat an empty or partial read as "it died" -- a background process's stdout can still be buffering (e.g. behind a `| tail -N` pipe) even though the process is alive and progressing normally. Wait for the actual completion signal (task-notification / exit code) before concluding a failure, or you'll report a false "died silently" and waste a round re-running work that was already succeeding.

Related: [[deterministic-repro-fast]]
