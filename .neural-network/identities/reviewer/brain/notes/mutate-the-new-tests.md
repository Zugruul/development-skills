---
tags: [review, testing, mutation]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "#543"
confidence: direct
graduated: false
created: 2026-11-05
last-touched: 2026-11-05
---

A green new test proves nothing until removing the code it covers makes it fail.

## What to do
- Delete or invert each new guard on an exported copy, then run the section.
- A surviving mutation is a finding, even when the behaviour is correct today.
- Do this on hardening fixes first: their tests often pin only the one reported input.

## Why it paid off
Validity checks could be deleted with every test still green, which hid a crash on a null field.
