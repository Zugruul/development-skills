---
tags: [gate, debugging]
paths: ["plugins/spec-workflow/tests"]
strength: 1
source: "retro 394/395 close (mis-attribution incident)"
graduated: false
created: 2026-07-24
---

The gate chains THREE independent legs — the test suite, shellcheck, and manifest validation — and any one fails it. When the gate goes red, check all three before rerunning anything: the linter and validator legs cost seconds while a suite rerun costs minutes, and an info-severity lint finding on a brand-new line (SC2016 on pinned-phrase backticks) is exactly the failure a suite-only diagnosis misses. Extends [[attribute-red-gate-to-sections-first]]: sections-first WITHIN the suite leg, but legs-first overall.

Related: [[attribute-red-gate-to-sections-first]] [[gate-verdict-before-merge]]
