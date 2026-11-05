---
tags: [review, scope]
paths: ["**"]
strength: 1
source: "#543"
confidence: direct
graduated: false
created: 2026-11-05
last-touched: 2026-11-05
---

A fresh reviewer of the whole diff finds what rounds of focused reviews stop seeing.

## What happened
After two clean spec passes, an independent reviewer found that a stated requirement was only half met: lanes were created through the helper but never removed.

## What to do
- Check each SHALL in the delta against the whole diff, and quote the file that satisfies it.
- A test that pins one of several required files can pass while the others are missing.
