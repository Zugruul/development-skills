---
tags: [design-docs, scope]
paths: ["**"]
strength: 1
source: "PR#243 (#235) -- design doc didn't specify how to classify a test+doc-only mix commit; resolved as impl-touching (stricter), flagged the interpretation explicitly rather than silently picking one"
graduated: false
created: 2026-07-20
---

When a design doc leaves an edge case genuinely unspecified in an ENFORCEMENT/compliance check (not a feature), resolve the ambiguity toward the STRICTER interpretation (more likely to catch a real violation) rather than the looser one, and state the resolution explicitly in the PR report so the orchestrator/reviewer can judge it rather than silently picking one. A stricter-than-specified check can be relaxed later if it proves too noisy; a looser one that misses real violations defeats the whole point of adding enforcement.

Related: [[acceptance-criterion-outranks-test-spec-paraphrase]]
