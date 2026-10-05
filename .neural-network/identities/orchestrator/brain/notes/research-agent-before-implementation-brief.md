---
tags: [briefing, research, efficiency]
paths: ["**"]
strength: 1
source: "PR#140 MEM-032 feedback triage"
graduated: false
created: 2026-07-18
---

Spawning a research-only agent to map existing code locations, existing function/API signatures, and existing test patterns BEFORE writing an implementation brief produces a more precise brief with concrete file:line references and reduces mid-task clarification rounds -- especially valuable for a task that extends existing machinery (a new code path unioning with an established one) rather than building something from scratch.

Recurrence (MEM-032): a dedicated research pass mapping brain.py's recall function, the MEM-031 embedding-index API, and existing test fixture patterns let the dev brief cite exact line numbers and function signatures up front -- the dev agent needed zero clarifying round-trips before landing a correct implementation on the first pass (the only fix round came from independent review, not from an ambiguous brief).

Related: [[parity-check-new-vs-existing-path]]
