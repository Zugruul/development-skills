---
tags: [review, coverage, probes]
paths: ["**"]
strength: 1
source: "#96 review r1 (3 of 34 sections sampled; one loop found F1+F2)"
graduated: false
created: 2026-07-08
---

When the artifact's contract is universal over a set S, enumerate S from the code (the array/registry is usually right there) and drive the operation once per member, diffing outcomes — `for s in <all members>; do op "$s"; echo "$s rc=$?"; done`; the odd exit codes ARE the findings. Dev tests almost always sample the EASY members; the bugs live in the structurally-different ones. This is the sharp edge of standing rule 1: "adversarial inputs" means specifically the members of the claimed input set the shipped tests skipped.

Related: [[emission-vs-assertion]]
