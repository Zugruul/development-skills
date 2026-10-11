---
tags: [review, argv, installer, security]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "#347 round 1 literal path substitution and round 2 sibling binding probes"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Test Literal Bindings Through Every Transformation

- An argv array avoids shell parsing, but a shared adapter can still substitute placeholders inside supposedly literal interpreter, engine or policy paths.
- Exercise all sibling binding positions through the installed command, not only the argument-building helper. A changed policy path can alter authority even when provisioning passed.

## Keep Refusals Narrow

- Where literal escaping is unsupported, reject conflicting syntax before installation writes instead of changing shared adapter semantics.
- Test known and unknown placeholders, isolated delimiters, resolved engine aliases, existing-file preservation and normal paths with spaces.

Related: [[reproduce-before-verdict]] [[reports-are-not-the-code]]
