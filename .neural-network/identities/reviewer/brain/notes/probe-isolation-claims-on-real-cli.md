---
tags: [review, isolation, cli, verification]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "PR-close #309 review r1"
graduated: false
created: 2026-07-22
---

For any isolation/boundary claim in a diff, verify against the REAL binary with a no-auth probe before accepting the docstring: codex debug prompt-input renders the model-visible prompt without authentication and exposed a global-AGENTS.md leak that six pinned flags and an honest-looking docstring all missed. Flag-audit tables (flag → exists? → claimed purpose honest?) against the CLI's own --help are the standard shape for adapter reviews.

Related: [[reports-are-not-the-code]] [[write-site-classification-sweep]]
