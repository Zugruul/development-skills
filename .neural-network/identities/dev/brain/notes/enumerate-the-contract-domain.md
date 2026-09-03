---
tags: [testing, coverage, tdd]
paths: ["**"]
strength: 1
source: "#96 retro (r1 sampled 3 easy sections of 34; reviewer converged independently)"
graduated: false
created: 2026-07-08
---

When a feature's contract is "works for EVERY element of set X" (every registered section, file type, verb), the RED test must enumerate X — loop the actual inventory and assert each element, e.g. `for s in "${SECTIONS[@]}"; do run --section "$s"; assert rc=0; done`. Hand-picking cheap samples tests your assumptions, not the contract: the failures live precisely in the structurally-different members you'd never pick (the ones with hidden coupling). The domain enumeration usually already exists in the code — read it and drive every element.

Related: [[red-commit-as-you-go]] [[swallow-fix-matrix]]
