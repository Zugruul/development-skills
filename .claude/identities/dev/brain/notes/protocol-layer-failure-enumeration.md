---
tags: [protocols, parsing, subprocess]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "PR-close #339"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

Input validation has two layers: the caller's values (schema) AND the peer's responses. For a wrapper parsing another process's output, ask "what can a well-behaved-but-imperfect peer legitimately do that isn't a value mismatch" — noise before the payload, two failure signals at once (error reply + nonzero exit) — and decide explicitly which wins when two are true. The round-2 findings all lived there, not in the input layer.

Related: [[validate-the-declaration-not-just-values]]
