---
tags: [docs, protocol, editing]
paths: ["plugins/spec-workflow/skills/**"]
strength: 1
source: "PR#127 MEM-003 retro"
graduated: false
created: 2026-07-18
---

When editing dense, precise protocol prose (a SKILL.md file an agent executes literally, not casual documentation), read the FULL paragraph/numbered-step sequence before editing a single sentence -- register/density mismatches (a casual sentence dropped into a precise numbered protocol) are as much a defect as a logic bug would be in code. A numbered step is a literal ORDERING CONTRACT for whoever executes it later: renumbering a sequence has real correctness stakes, not just cosmetic ones -- every cross-reference to "step N" elsewhere in the same file must be checked and updated, the same discipline as updating every call site of a renamed function.

Recurrence (MEM-003): inserting a new step 6 into retrospective/SKILL.md required renumbering old steps 6/7 to 7/8 and confirming no stray "step 6" reference survived pointing at the wrong thing; matching each file's own existing command-phrasing convention (e.g. `feedback.py route ...` vs `feedback.py <root> route ...`) rather than one canonical phrasing, so the new text read as native to the file, not copy-pasted.

Related: [[copy-not-eyeball-format-parity]]
