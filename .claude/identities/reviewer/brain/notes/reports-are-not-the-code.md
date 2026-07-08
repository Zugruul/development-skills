---
tags: [review, claims]
paths: ["**"]
strength: 2
source: "#97 review retro — recurrence (comments can be wrong about the code)"
graduated: false
created: 2026-07-08
---

A specific, checkable claim in a report OR a code comment is a POINTER, not a fact — reconstruct the described behavior yourself (the residual-collision comment was verified by reproducing it; boundary math by driving pid 0/199/200/65535, edges the shipped tests never probed). The report describing the code is one step from ground truth; a comment describing intended behavior can be wrong about actual behavior.

Related: [[fixture-provenance-check]] [[fetch-before-merge-forward]]
