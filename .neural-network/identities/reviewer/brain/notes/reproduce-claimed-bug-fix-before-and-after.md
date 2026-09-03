---
tags: [review, verification]
paths: ["**"]
strength: 1
source: "PR#229 (CDX-021, #186) review -- reproduced the dict-keys bug on main, confirmed it's gone on the PR branch, same fixture both times"
graduated: false
created: 2026-07-19
---

When a PR claims to fix a specific latent bug (not just add a new feature), reproduce the ORIGINAL bug yourself on main first (build the exact fixture/input that triggers it, confirm the bad output), then confirm the SAME fixture produces correct output on the PR branch. This is stronger than trusting a dev's self-reported repro or a passing test alone -- a test can pass while accidentally testing the wrong thing, but reproducing the actual before/after behavior change directly proves the fix works.

Related: [[verify-tdd-empirically-when-log-is-thin]] [[verify-backcompat-claims-algebraically]]
