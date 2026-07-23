---
tags: [testing, fixtures, classification]
paths: ["plugins/spec-workflow/scripts/assistant"]
strength: 1
source: "retro AST-020 (dev interview)"
graduated: false
created: 2026-07-22
---

Before writing fixtures for a classifier, read the ACTUAL validator's required-key set instead of guessing which inputs produce which outcome kind. Ordering is where the subtlety lives: structural validity checks short-circuit before state checks (e.g. a section missing an optional flag validates cleanly and classifies by the state check, not as invalid). Fixture expectations derive from the real code path, never from what the field names suggest.

Related: [[capture-dont-transcribe]]
