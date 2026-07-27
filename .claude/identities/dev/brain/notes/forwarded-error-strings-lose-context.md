---
tags: [errors, messages, layering]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "PR-close #337 review"
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

An exception message accurate at its origin can mislead at its destination: adapters.NotFound's "provider CLI could not be executed" wording was right for provider adapters but wrong once forwarded verbatim into a provisioning-check reason rendered in the persona prompt. When forwarding an error across a layer boundary, ask "where does this string end up, and does it still make sense there" — author the boundary's own message and pull detail from exc.__cause__.
