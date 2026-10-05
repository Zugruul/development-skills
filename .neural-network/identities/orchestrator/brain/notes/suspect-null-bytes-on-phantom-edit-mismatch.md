---
tags: [debugging, editing, encoding]
paths: []
strength: 1
source: "feedback item 1, 2026-07-11T04:20:00Z"
graduated: false
created: 2026-07-11
---

If an Edit/string-replace call reports "string not found" even after a
fresh read shows the text matching character-for-character in a normal
render, suspect an embedded non-printable byte (stray null byte,
zero-width char) rather than re-reading and retrying the same match.
Normal text tools — including grep — can silently fail to see or search
across such a byte. Dump the suspect range as a raw Python repr() of the
bytes to actually check.
