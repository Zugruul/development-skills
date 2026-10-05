---
tags: [tdd, process, git]
paths: []
strength: 1
source: "#406+#408 retro 2026-07-26"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

Never leave a red-only commit as the branch tip while doing ANY other work (extra verification runs, broader gates) — commit red, then immediately implement and commit green as one atomic pair. A stash-cycle proof of red→green is NOT red-first: it leaves no history evidence and the reviewer must treat TDD order as violated. Two independent occurrences on 2026-07-26 (#406: red mandate test sat as tip while a full-suite run interleaved; #408: test+fix landed as one commit with only a stash-proof).
