---
tags: [review, concurrency, idempotence]
paths: ["**"]
strength: 1
source: "#92 review retro"
graduated: false
created: 2026-07-08
---

An idempotence guard spelled as EQUALITY-to-target (cur == target) is a standing tell: it only prevents re-applying the identical op, never understands ordering. Always ask "what if current state has moved PAST the stale op's target?" — then construct the two-op interleaving concretely from the code's actual append/replay order.

Related: [[outcome-language-marks-unverified-seams]] [[red-passing-checks-may-pin-later]]
