---
tags: [review, method]
paths: ["plugins/spec-workflow/skills/build-next/references/auto-review.md"]
strength: 1
source: "feedback 2026-08-01 item 1, four reviews"
graduated: false
created: 2026-08-01
last-touched: 2026-08-01
---

Label every finding CONFIRMED (reproduced by driving the real code) or PLAUSIBLE, and in re-review rounds mutation-test that the new tests actually pin the fixes — revert the fix on a scratch copy and count failing assertions. This discipline caught a 4x unit error headed into spec text, a marker-file path-smuggling flow, and a feature hidden in the exact configuration the human runs — all invisible to a green gate.
