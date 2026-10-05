---
tags: [tests, fixtures, subprocess]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "#408 root cause"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

Any test that (even indirectly) invokes an external CLI needs an explicit stub/PATH-isolation fixture, or it silently depends on whatever binaries the machine happens to have — section-assistant-selection's engine chat call used the ambient PATH and only ever passed because dev machines have codex installed.

Related: [[adapter-contracts-enumerate-os-failures]] [[verify-fixture-isolates-intended-path]]
