---
tags: [parsers, guards, review]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#552 review"
confidence: direct
graduated: false
created: 2026-11-06
last-touched: 2026-11-06
---

A hand-written parser that shadows a real one needs a generated search, not only clever cases.

## What happened
- Three adversarial rounds each found new disagreements between a guard's lexer and rustc.
- The independent reviewer then built candidates from token grids and random atoms, ran the guard, and built every accepted candidate with rustc.
- The grid found the literal-suffix family at once, and proved clean after the fix: about 49,000 candidates, 0 hits.

## What to do
- Have the real compiler judge what the guard accepted.
- Show the search can find a known bypass before trusting a clean result.
- Report "no known way through", not "proven sound": it covers only the tokens tried.
