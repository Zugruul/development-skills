---
tags: [verification, ci, qa]
paths: ["**"]
strength: 1
source: "PR#190 CDX-040 feedback triage"
graduated: false
created: 2026-07-18
---

When a task never involving CI (application code) reaches "gate green," that alone is sufficient completion evidence. But when a task DEFINES its own acceptance criterion as a live external system's behavior (CI passing, a deployed service responding), the orchestrator should treat the task as unverified until it has directly observed that live system's outcome, not just the local artifacts (gate runs, diffs, review passes) that are SUPPOSED to produce it.

Recurrence (CDX-040): a shellcheck version-skew bug (older shellcheck on the CI runner false-flagging a redeclared-but-identical function) was invisible to local gate green, the diff, the design doc, and TWO independent review passes -- it only surfaced by actually pushing and watching the real GitHub Actions run. The task's own DoD ("CI green on a real PR/push") existed precisely because this class of bug can hide behind every other verification layer.

How to apply: before moving a task past QA when its acceptance criterion names a live external system, add an explicit "observed the live system directly" step distinct from "ran the local gate" -- do not conflate the two.

Related: [[local-gate-green-doesnt-imply-ci-green-for-infra]]
