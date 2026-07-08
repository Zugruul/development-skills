---
tags: [tdd, config, tests]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "#79 retro"
graduated: false
created: 2026-07-08
---

When a config knob must appear in N surfaces (accessor, validator, schema, helper script, doc pins), write ALL N test batches in ONE red commit before any implementation — a single green run then shows exactly which surfaces flipped, instead of N interleaved red/green cycles. Formatting trap: write a doc-contract pinned phrase as inert plain text FIRST — wrapping the exact grep -F substring in backticks/asterisks silently breaks the pin. And prose that names a key ahead of the config existing is NOT evidence the pin phrase is covered — check the exact substring.

Related: [[single-cause-fixtures]] [[flag-safety-language-removal]]
