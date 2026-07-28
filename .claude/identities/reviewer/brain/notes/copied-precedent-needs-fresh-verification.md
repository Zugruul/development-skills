---
tags: [review, patterns, provenance]
paths: ["**"]
strength: 1
source: ""
confidence: direct
learned-from: #474
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

When a diff justifies itself with "mirrors the pattern X already established" / "same as Y's precedent", treat that as a FLAG, not reassurance: copied-pattern language means the author took the precedent as pre-vetted, which is exactly when nobody re-checks it. Re-verify the precedent's own correctness from scratch — concretely, ask whether the precedent was ever driven through its OWN full real-code path or only unit-tested in isolation. In #474, toggleSttListening's snapshot-then-emit span code had sat since #454 with only stub-level coverage; speakReply consciously copied it and inherited the latent double-span bug by design, not accident.

Related: [[comments-deserve-code-scrutiny]] [[stub-shaped-blind-spots]]
