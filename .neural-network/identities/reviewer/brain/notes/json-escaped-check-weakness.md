---
tags: [review, tests, encoding]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "#70 review retro"
graduated: false
created: 2026-07-08
---

A check_absent for a raw control byte (ESC) in a JSON body is non-discriminating — json.dumps escapes control chars, so it passes on red AND fix. Assert on the literal text that survives the encoding (e.g. the SGR fragment "[1;35m"). Generally: prove a check discriminates by running it against both the red and fixed states before crediting it.

Related: [[verify-guard-regex-on-real-artifact]]
