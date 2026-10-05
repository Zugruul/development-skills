---
tags: [lint, comments, gate]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #447"
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

Keyword-matching lints (the bash-version-floor scanner) flag the literal token even inside a comment explaining why you AVOIDED it — the scanner cannot tell "I use X" from "I do not use X because". When documenting an avoidance, describe the concept instead of naming the banned token.
