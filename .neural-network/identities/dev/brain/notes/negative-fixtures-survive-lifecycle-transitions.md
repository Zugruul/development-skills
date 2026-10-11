---
tags: [testing, fixtures, lifecycle]
paths: ["plugins/remote-compute/tests/**", "docs/spec-deltas/**"]
strength: 1
source: "development-skills#194 independent review round 2 and lifecycle replay"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Keep negative fixtures negative across lifecycle changes
- Do not derive an obsolete or invalid fixture from the current canonical document when the workflow intentionally replaces that document.
- Construct the invalid state explicitly, so folding or archiving cannot silently turn it into valid input.
- Exercise the whole relevant test class before and after the real transition. A direct helper probe can pass while a sibling test now asserts the wrong result.

Related: [[bind-contract-checks-to-clauses]] [[separate-live-repo-state-tests-from-fixtures]]
