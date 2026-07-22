---
tags: [process, pacing, background, monitor]
paths: ["**"]
strength: 1
source: ""
confidence: direct
learned-from: GL-050 #300 stalls
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

When a long-running check (gate, CI) is correctly backgrounded/Monitor-gated, the completion notification is the TRIGGER for the mutation it was gating (fix -> re-run -> add -> commit -> report), executed immediately in that same turn — not an occasion for another status update. Two GL-050 stalls came from ending turns on "waiting/done" messages with the commit still unmade; the orchestrator had to finish the close on-behalf. Finish-line steps after a wait are one atomic sequence.
