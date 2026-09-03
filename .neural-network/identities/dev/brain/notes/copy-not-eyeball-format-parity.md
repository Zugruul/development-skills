---
tags: [testing, style, invariants]
paths: ["**"]
strength: 1
source: "PR#126 MEM-002 retro"
graduated: false
created: 2026-07-18
---

When mirroring an existing command's output format for a NEW command, do not eyeball-match the f-string -- copy the literal line and paste it, then write a test that asserts the exact same substring the existing command's own tests already assert. Byte-for-byte format parity between two commands is a TESTABLE INVARIANT, not a style guideline -- treat it that way, or a later edit to one command will silently drift from the other with nothing catching it.

Recurrence (MEM-002): `cmd_archived`'s render line was copied verbatim from `cmd_pending`'s (`f"{ts}\t{i}\t{item.get(\x27category\x27, \x27\x27)}\t..."`), and a test explicitly asserts format parity against the same substring `pending`'s own tests check.

Related: [[vocab-dict-fake-embedder]]
