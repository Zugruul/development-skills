---
tags: [orchestration, diagnosis, board-truthfulness]
paths: ["**"]
strength: 1
source: ""
confidence: direct
learned-from: GL-050 #300 close
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

Do not name a suspected known issue as the cause of an agent stall in board comments/reports until the agent (or evidence) confirms it — GL-050's dev stalls pattern-matched a known classifier-block bug but were actually pacing after Monitor-gated waits, and the board comment needed a correction. An idle_notification is not a blocked signal; interview first, attribute after. Cheap protocol: state the observable ("stalled at commit step, no report") and the action taken, put the suspected cause in the interview question, not the public record.

Related: [[board-moves-before-branch-delete]]
