---
tags: [api, claude-cli, verification]
paths: []
strength: 1
source: "CDX-054 (#203) -- claude -p envelope shape + --model alias reliability"
graduated: false
created: 2026-07-16
---

When an API responds with a wrapped envelope containing session/cost metadata alongside the actual payload (e.g. claude -p --output-format json's top-level result envelope with the real content nested at .structured_output), always investigate the real response shape via a live invocation before designing the parser -- assuming a bare top-level payload (matching a superficially similar API like codex's --output-schema) would have silently broken this integration. Also: a --model flag accepting an alias may not reliably resolve it -- verify with a real call before shipping, and restrict to full canonical ids if aliases prove unreliable.
