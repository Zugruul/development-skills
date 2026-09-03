---
tags: [review-protocol, auto-merge]
paths: []
strength: 1
source: "#397 retro"
graduated: false
created: 2026-07-24
---

When the final relay round's REQUEST_CHANGES comes with an exactly-specified minimal fix (the reviewer prescribes the line), have the dev apply it verbatim and ask the reviewer only to ACK its own prescription with its existing repro — framed explicitly as verdict-completion, not a new round. This closes reviewer-prescribed one-liners inside the 3-round cap without either merging over an open MAJOR or dumping a trivial fix on the human. Also: relay the orchestrator's own suspicions into the verify brief (the #397 fold regression was caught because the verify request named it explicitly).
