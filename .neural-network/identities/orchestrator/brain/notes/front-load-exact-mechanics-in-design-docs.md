---
tags: [design, briefing, review-efficiency]
paths: ["docs/design/**"]
strength: 1
source: "PR#126 MEM-002 retro"
graduated: false
created: 2026-07-18
---

Front-loading EXACT MECHANICS (not just requirements) into a task's design doc -- the literal format string to reuse, the exact sort/filter logic, the exact inclusive/exclusive boundary semantics -- shrinks review time proportionally, because the review reduces to "diff this against N stated decisions" rather than "evaluate whether these decisions were reasonable." Most of the design risk gets retired before implementation starts.

Recurrence (MEM-002): the design doc (docs/design/mem-E0.md) explicitly named the format string to reuse (byte-identical to cmd_pending's), the exact glob/sort mechanics, and the `>=` boundary semantics for --since -- the resulting review was fast and low-ambiguity, verifiable via a handful of concrete diffs against those 5 stated decisions rather than open-ended judgment calls. It also let scope-checking collapse to one `git diff --stat` against the design doc's explicit out-of-scope list.

Related: [[audit-new-path-parity-before-writing]]
