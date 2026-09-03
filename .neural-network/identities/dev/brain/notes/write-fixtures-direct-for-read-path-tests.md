---
tags: [testing, fixtures, isolation]
paths: ["**"]
strength: 1
source: "PR#126 MEM-002 retro"
graduated: false
created: 2026-07-18
---

When testing a READ path (a query/list command) that consumes data normally produced by a separate WRITE path, write the test fixture data DIRECTLY into the target file/format rather than round-tripping through the full write pipeline (emit -> route -> archive, etc.) to produce it. Faster, and keeps each test isolated to only the behavior actually under test -- a read-path test failure then unambiguously means the read path is broken, not the write path it would otherwise also be exercising.

Recurrence (MEM-002): `archived`'s tests write fixture YAML directly into `.claude/feedbacks/archive/<month>.yaml` rather than emitting+routing+archiving real records to produce archived data -- same shortcut an existing regression case in this file already used.

Related: [[verify-fixture-isolates-intended-path]]
