---
tags: [briefing, triage]
paths: ["plugins/spec-workflow/skills/**"]
strength: 1
source: "#55 retro (dev feedback)"
graduated: false
created: 2026-07-08
---

A plausible root-cause hypothesis written into a brief ANCHORS the dev's investigation even when wrong (#55's brief guessed a POST/GET commit race; the real bug was a lying health check). State hypotheses explicitly as hypotheses-to-falsify with the evidence that suggested them, and put "prove the root cause before fixing" above any specific guess — that instruction, not the guess, is what surfaced the real bug.

Related: [[pre-diagnose-before-brief]] [[no-change-claims-need-interaction-flags]]
