---
tags: [review, errors, probes]
paths: ["**"]
strength: 1
source: "#50 review (found the rc0-empty gap)"
graduated: false
created: 2026-07-08
---

Default probe on ANY loud-fail / fail-closed fix: the shipped test almost always covers only the failure branch. Drive the case where the SAME empty/zero/null result arrives on the SUCCESS path (rc=0, empty stdout — fresh repo, zero rows) and confirm it takes the benign path, not the new error path. Bug and correct-empty look identical in output; only the rc distinguishes them — the fix is proven only when rc0-empty→proceed AND rc≠0→fail are both shown. Companion triage for a new exit-1 replacing a tolerant path: enumerate callers (already `|| exit 1`?) and check whether the verb sits on the queue/retry substrate — setup-time + already-fatal callers + off-substrate = correct fail-fast, not a regression.

Related: [[reports-are-not-the-code]]
