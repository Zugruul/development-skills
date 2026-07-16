---
tags: [testing, tdd, codex]
paths: []
strength: 1
source: "task #179 (CDX-007)"
graduated: false
created: 2026-07-16
---

When an acceptance criterion requires proof that depends on something that can't run in CI (a real LLM call, real cost, real auth, non-determinism), split the evidence into two tiers: a hermetic always-green automated tier that proves everything scriptable (install, discovery, standalone execution of the real backing script), and a separate, clearly-documented manual tier for the part that genuinely needs a live model.

Why: #179 (CDX-007)'s acceptance was "install a plugin, run a skill, prove it completes" -- but proving a model actually DISCOVERS and INVOKES a skill from natural language requires a real `codex exec` call (cost, auth, non-determinism), which doesn't belong in the always-green suite. Splitting it meant the hermetic tier (22 checks, no model calls) runs on every gate, while the manual tier is a documented, reproducible script a human (or reviewer) runs by hand -- and was actually run for real twice (dev + reviewer, independently) rather than left as an unverified claim.

How to apply: don't force a non-deterministic/costly dependency into the hermetic suite (it'll be flaky or expensive) and don't skip the hard part either (that leaves the strongest evidence unverified) -- write the hermetic proof for everything genuinely scriptable, and a clearly-labeled, well-documented manual companion script (header explains what/why/how) for the rest. When failure modes surface while building the manual tier (missing auth, sandbox restrictions), handle and document them precisely rather than working around them silently.
