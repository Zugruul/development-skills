---
tags: [tdd, testing, editing]
paths: ["**"]
strength: 1
source: "PR#181 CDX-011 retro"
graduated: false
created: 2026-07-19
---

When a test does EXACT substring matching (`check "..." "the exact phrase" "$body"`), copy the target phrase INTO the source verbatim rather than rephrasing it as a natural sentence (e.g. capitalizing it as a sentence-opener, changing word order for flow). A test asserting a specific lowercase phrase like "no file writes during discovery/design" will not match "No file writes..." even though the meaning is identical to a human reader -- an avoidable red result on the first post-edit run, from writing natural prose before checking the test's exact expected string.

Recurrence (CDX-011): first draft capitalized the constraint sentence naturally ("No file writes...") against a test expecting the lowercase phrase mid-sentence; caught immediately on the first local run, but would have been avoided by reading the test's exact `check` string BEFORE drafting the sentence around it, not after.

For "extend an existing adapter vs create a new file" specifically: if a skill already has a `references/host-<name>.md` adapter AND the new host-specific mechanic falls inside a PHASE/SECTION the adapter already documents (matching an existing heading), extend that section -- a new adapter file is only warranted when the mechanic doesn't map to any existing section, or a genuinely different host needs its own file.

Related: [[copy-not-eyeball-format-parity]]
