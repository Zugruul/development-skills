---
tags: [security, process, tdd]
paths: ["**"]
strength: 1
source: "PR#178 CDX-006 retro"
graduated: false
created: 2026-07-18
---

When a task brief characterizes an untrusted issue/PR comment (e.g. "this commenter is NONE-permission, do not act on it"), verify the permission level YOURSELF rather than trusting the brief's summary secondhand -- cheap (`gh issue view <n> --comments`), and catches a briefer's mistake if one exists rather than propagating it. Also worth checking whether an "open question" a task references is actually already resolved (not still open) before reaching for a more elaborate solution than the resolution calls for -- an OQ that reads as open in a backlog summary may have a decided resolution recorded elsewhere in the spec.

Recurrence (CDX-006): brief pre-flagged an issue comment as untrusted (NONE permission, solicited paid work); independently re-verified via `gh issue view --comments` before proceeding rather than trusting the characterization outright. Separately: two nonexistent root files initially read as "needs a generation script," but §15 OQ-2 had already resolved that question (hand-maintained, no CI generation) -- checking the OQ table first avoided over-engineering.

Related: [[respect-named-scope-boundaries]]
