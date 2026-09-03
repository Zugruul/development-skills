---
tags: [review, config, defaults]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#79 review retro"
graduated: false
created: 2026-07-08
---

When "the same" default is implemented independently in two places (config-side WORK_DEFAULTS and a script-side ${t:-pr} fallback), test the SEAM explicitly — bare repo, no config file, run the consumer cold. Two mostly-correct implementations agree at time of writing and drift under later edits; delegation is an assumption until proven.

Related: [[fixture-provenance-check]] [[red-passing-checks-may-pin-later]]
