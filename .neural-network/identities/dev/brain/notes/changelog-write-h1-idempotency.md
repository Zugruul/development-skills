---
tags: [bash, idempotency, text-generation]
paths: ["plugins/spec-workflow/scripts/changelog.sh"]
strength: 1
source: "#165 local-route fix"
graduated: false
created: 2026-07-15
---

Text idempotency fixes (re-running a --write/append-style command against its own prior output) must strip the marker it's about to re-add — check for it verbatim as the first line and drop it + any immediately-following blank lines — before re-prepending. Trace every string-shape edge case by hand (empty marker-only file, marker-without-blank-line, no-marker-at-all) rather than trusting the happy path.
