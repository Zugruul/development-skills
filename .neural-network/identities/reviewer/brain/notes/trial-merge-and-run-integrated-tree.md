---
tags: [review, integration, batches]
paths: []
strength: 1
source: "batch2b/3/4 2026-07-26"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

For multi-branch batches, TRIAL-MERGE the recommended chain in a scratch clone and RUN the touched sections on the integrated tree — never just predict from hunk offsets. This is the only review posture that catches cross-branch collisions: two sibling branches each defined a top-level emitVoiceSpan with incompatible signatures; git merged silently, the later hoisted over the earlier, and STT spans would have silently stopped reaching the server in production. Three consecutive batch reviews (2026-07-26) confirmed the pattern pays.

Related: [[reports-are-not-the-code]]
