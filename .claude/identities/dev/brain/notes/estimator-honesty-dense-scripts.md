---
tags: [python, tokens, unicode, budgets]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "PR-close #311 review r2"
graduated: false
created: 2026-07-22
---

chars/4 token estimators undercount dense scripts (CJK/emoji) 4-8x — enough to blow a documented headroom silently. Charge codepoints above U+2E7F at ~1 token each and state the residual error band in the docstring; estimator honesty beats estimator precision.

Related: [[defaults-need-own-tests]] [[bool-before-int-guard]]
