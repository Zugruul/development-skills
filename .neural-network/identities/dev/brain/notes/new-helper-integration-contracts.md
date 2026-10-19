---
tags: [testing, integration, portability]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "#241 retrospective: independently reproduced workflow boundary"
confidence: direct
graduated: false
created: 2026-10-19
last-touched: 2026-10-19
---

## Check the surrounding registration contract

A new helper or test section participates in existing repository rules beyond its focused behavior. Before declaring it ready, inspect adjacent integration checks: runtime-state manifests and ignores, exact-list tests, documentation tables, standalone section guards, and host-neutral skill path rules.

## Copy current rules, then verify

Historical reference examples can predate the current skill contract. Run the relevant existing checks early, alongside tests for the new behavior; copying an older example is not evidence that the current policy accepts it.

Related: [[batch-red-across-surfaces]] [[no-stage-specific-path-assertions]]
