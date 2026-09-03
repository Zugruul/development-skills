---
tags: [testing, fixtures, embeddings]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR#140 MEM-032 test design"
graduated: false
created: 2026-07-18
---

For a fake-embedder test stub, use a small fixed VOCAB -> vector-dimension dictionary (each vocab word's presence increments a specific component) instead of a hash/length-based scheme. This gives full manual control over cosine similarity between fixture texts -- you can construct exact intended rankings (strong/medium/irrelevant match) deterministically, including a genuine zero vector for "no shared vocabulary" (rather than a nonzero fallback that silently breaks isolation -- see [[verify-fixture-isolates-intended-path]]).

For isolating a link-bridging-specific bug: force --k 1 (or the tightest breadth parameter available) so only the single intended note can ever be a DIRECT neighbor, making the target's only route into the output the hop/spread mechanism actually under test.

Related: [[verify-fixture-isolates-intended-path]]
