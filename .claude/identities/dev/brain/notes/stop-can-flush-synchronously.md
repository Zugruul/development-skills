---
tags: [voice, lifecycle, races]
paths: ["plugins/spec-workflow/templates/**"]
strength: 1
source: ""
confidence: direct
learned-from: #474
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

Teardown APIs are not inert: this template's engine.stop() synchronously delivers a buffered result (silence-timer flush -> onResult -> onSttText) BEFORE returning — so any caller that snapshots state, calls a stop/teardown, then emits off the snapshot can double-act on a turn the stop itself already closed (#474: two terminal spans + a half-spoken fragment sent as a ghost message, at TWO call sites that copied each other). Pattern: after calling any stop/teardown that could deliver results, re-check the LIVE state (window.__sttSpanId === snapshot) before emitting; never trust a pre-call snapshot alone. When adding a new stop path, grep for existing snapshot-then-emit callers — the bug shape propagates by imitation.

Related: [[anonymous-listener-slice-eval]] [[deterministic-repro-fast]]
