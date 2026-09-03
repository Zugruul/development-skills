---
tags: [review, lifecycle, timing]
paths: ["**"]
strength: 1
source: "#98 review retro"
graduated: false
created: 2026-07-08
---

A retry/poll loop's correctness can't be proven by start/end state — "eventually consistent" and "instant success" look identical there. Drive it at the BOUNDARY: a fixture that resolves mid-window (e.g. a SIGTERM handler sleeping past one tick but inside the bound) plus wall-clock timing distinguishes "genuinely polls" from "lucky iteration 1" from "doesn't loop at all".

Related: [[probe-with-real-repos]] [[red-passing-checks-may-pin-later]]
