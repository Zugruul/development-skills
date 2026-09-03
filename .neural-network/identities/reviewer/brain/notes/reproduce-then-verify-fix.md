---
tags: [review, repro, verification]
paths: ["**"]
strength: 1
source: "retro 2026-07-21 GL-003/GL-004 reviews"
graduated: false
created: 2026-07-21
---

A finding is strongest as a runnable repro, and round-2 verification is re-running that EXACT repro against the fix — not reading the diff. Session evidence: a wrong-type crash (traceback → warn-once/exit-0 after fix) and an apply-path write (links.json rewritten → byte-identical after fix) were both confirmed fixed this way, and both fixes' red commits were confirmed genuinely red at the pre-fix tree.

Related: [[rerun-the-red-empirically]]
