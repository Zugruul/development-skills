---
tags: [fixtures, anti-circularity, review]
paths: ["**"]
strength: 1
source: "#91 review (nearly mis-flagged 5 assertion strings as unmigrated)"
graduated: false
created: 2026-07-08
---

In fixture-sourcing / anti-circularity tasks, grep for a trigger string hits BOTH sides — classify by side before flagging: the string on the fake binary's EMISSION side (echo/>&2) must be corpus-sourced (inline = violation); the identical string inside check/check_absent is the SPEC of what the detector should surface and correctly stays inline. Companion move: a claim stated in a fixture header or dev report is upgraded to a finding only by empirical proof (print the actual fields and diff them — that's what turned the core-vs-graphql reset aliasing from suspicion into a verified latent bug).

Related: [[fixture-provenance-check]] [[reports-are-not-the-code]]
