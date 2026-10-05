---
tags: [briefing, triage, orchestration]
paths: ["plugins/spec-workflow/skills/**"]
strength: 2
source: "#77 retro — recurrence (orchestrator's own gap)"
graduated: false
created: 2026-07-07
---

Verify the root cause yourself (exact lines, all stacked failure modes) BEFORE briefing — and for detection/classifier tasks, PASTE THE REAL CAPTURED BYTES (actual error strings observed live, with provenance) into the brief. The #77 brief said "detect rate-limit errors" while the orchestrator had the real masked text ("unknown owner type") in-context from three incidents that same night; the dev invented fixture text and the detector shipped blind.

Related: [[board-comment-bodies-via-file]] [[no-change-claims-need-interaction-flags]]
