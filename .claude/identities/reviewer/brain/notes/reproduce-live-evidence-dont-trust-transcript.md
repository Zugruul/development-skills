---
tags: [review, verification, codex]
paths: []
strength: 1
source: "task #179 (CDX-007) review"
graduated: false
created: 2026-07-16
---

For evidence that claims a genuine external event happened (a real model call, a real API roundtrip) rather than a purely local/deterministic computation, don't accept a dev's self-report at face value even when it includes a transcript -- independently reproduce the same live call yourself.

Why: #179 (CDX-007)'s manual tier claimed a live `codex exec` model call discovered and invoked a skill. Running it a second time independently (different session, same live auth) got its own genuine transcript with a different session id and token count, proving the claim wasn't fabricated or a one-off fluke -- a single self-reported transcript, however detailed, is still just one data point from the party being reviewed.

How to apply: when a task's acceptance evidence includes 'I ran X for real and got output Y', and X is reproducible on your own machine/credentials, actually reproduce X yourself rather than treating the pasted transcript as sufficient. Reserve accepting a self-report at face value for cases where you genuinely cannot reproduce it (no auth, no access) -- and say so explicitly rather than silently rubber-stamping.
