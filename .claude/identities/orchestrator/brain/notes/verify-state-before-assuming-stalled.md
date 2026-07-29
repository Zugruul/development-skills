---
tags: [process, subagents, concurrency]
paths: ["**"]
strength: 1
source: ""
confidence: direct
learned-from: 479
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

A subagent waiting on a long-running command is indistinguishable from a crashed one by its idle notifications alone — three devs in one session looked stalled while their multi-minute gate runs were healthy. Before re-briefing or taking over: check the actual process (pgrep the suite), the branch (commits present? tree clean?), and the recorded-pass mtime. Take over only when the evidence says the work truly died; and set take-over deadlines in nudges so silence has a defined consequence.

Related: [[self-authored-code-needs-adversarial-review]]
