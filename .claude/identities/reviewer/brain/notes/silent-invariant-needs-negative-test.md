---
tags: [tests, invariants, coverage]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR-close #337 review"
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

An invariant whose violation is SILENT (e.g. "disabled capability is never invoked" — no error, no output, just a subprocess that shouldn't exist) needs an explicit negative test asserting zero calls. The fixture already had the call-log hook and nothing used it. "Correct today with no test" is how landmines start; the zero-call assertion is nearly free when the fixture logs invocations.
