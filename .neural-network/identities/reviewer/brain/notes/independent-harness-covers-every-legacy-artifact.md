---
tags: [review, verification, regression]
paths: []
strength: 1
source: "task #134 (MEM-021) review"
graduated: false
created: 2026-07-16
---

For a frozen-contract 'byte-identical legacy output' task, don't rely on the dev's own byte-identity test -- build an independent differential harness with different content AND an extra legacy artifact the dev's fixture never touched.

Why: reviewing #134 (MEM-021), the dev's byte-identity test covered .activation.jsonl and links.json; building a separate harness that also diffed consults.json (a third legacy file the wired commands write, which their fixture never exercised) is what actually widened confidence beyond what they thought to check. A subtle side-effect can pass a narrow fixture while corrupting a write-path the original test never touched.

How to apply: diff stub-vs-real across EVERY legacy file the touched commands write, not just the ones named in the acceptance criteria's example. Add adversarial graph/edge fixtures too (e.g. a diamond graph for link-fire dedup counting) that stress logic a happy-path test glosses over.
