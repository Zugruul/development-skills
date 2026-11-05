---
tags: [testing, stubs, integration]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#543"
confidence: direct
graduated: false
created: 2026-11-05
last-touched: 2026-11-05
---

A stub of an external CLI only proves your code agrees with your assumption about that CLI.

## What happened
- A stub accepted every call, so all tests passed.
- The real tool refused calls made from a linked worktree.
- A "never fail" hook swallowed the refusal, so the feature silently did nothing.

## What to do
- Run one live check against the real tool, in an isolated session, before trusting stubs.
- When the real tool refuses something, teach the stub the same refusal.
- Log real responses while testing code that hides its errors.
