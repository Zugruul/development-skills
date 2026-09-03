---
tags: [review, security, artifacts, human-factors, browser]
paths: ["**"]
strength: 2
source: "human feedback 2026-07-28 (+reviewer remediation)"
confidence: direct
graduated: false
created: 2026-07-28
last-touched: 2026-07-28
---

ANY browser artifact an agent opens that a human might later find — security PoCs, layout repros, rendered probes — must self-identify in-band: an HTML comment plus a VISIBLE banner naming it a test artifact, the issue it belongs to, what it demonstrates, that any payload is inert, who made it, and that it is safe to close and delete. Task-scoped filenames (REVIEW-441-xss-repro.html), never bare xss.html. Do NOT reserve this for scary-looking content: an unlabeled file:// tab is the problem shape, and whether it alarms someone is not the agent's judgment to make on their behalf.

CLEANUP IS TWO ACTIONS, NOT ONE: deleting the files does not close the windows. A human returned to tabs reading "PWNED=1" whose underlying files had already been removed. Close the tabs AND delete the artifacts as soon as the finding is recorded; naming them in the verdict is the backstop, not the mechanism.
