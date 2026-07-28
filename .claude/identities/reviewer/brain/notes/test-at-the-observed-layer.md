---
tags: [review, tests, layers]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close batch #438/#338/#441"
confidence: direct
graduated: false
created: 2026-07-27
last-touched: 2026-07-27
---

A finding can only be caught by a test at its own layer or lower. Ask of every test: what does it actually observe? A grep observes file bytes; new Function observes the JS tokenizer; only a browser observes the HTML parser, layout, and execution. Three green suites in one batch each missed a real defect because the suite measured a lower layer than the bug lived at (flex layout, error-taxonomy branches, HTML element-splitting). When a change crosses layers — server to HTML to JS to paint — the tests must too.

Related: [[reproduce-before-verdict]]
