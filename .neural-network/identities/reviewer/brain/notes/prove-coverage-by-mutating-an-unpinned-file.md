---
tags: [review, tdd, test-coverage]
paths: []
strength: 1
source: "task #174 (CDX-002) review, round 1"
graduated: false
created: 2026-07-16
---

For mechanical multi-file migrations under review, spot-checking N files by exact-string assertion is not enough proof the test suite would catch a regression -- empirically mutate a file the test does NOT pin (not one it does) and confirm the suite goes red.

Why: reviewing #174 (CDX-002, 26 SKILL.md files migrated off `${CLAUDE_PLUGIN_ROOT}` to relative paths), the original test only pinned 3 of 26 files by exact string. Mutating one of the other 23 (`board/SKILL.md`, one directory level too shallow) sailed through every existing assertion green -- proving the coverage gap was real, not hypothetical. The delivered migration was correct; the test just couldn't have caught a regression in it.

How to apply: whenever a diff claims uniform-pattern correctness across many files but the test only spot-checks a handful, don't take the spot-check as proof of the whole -- pick a file outside the pinned set, mutate it, and watch the suite actually fail before approving. If it doesn't fail, that's a real (if non-blocking) finding, not a nitpick.
