---
tags: [config, migration, docs, spec-delta]
paths: ["plugins/spec-workflow/**", "SPEC.md", "docs/**"]
strength: 1
source: "PR#64 (#62) retro"
graduated: false
created: 2026-07-07
---

When a config default (path, name, id) changes, grep the WHOLE repo for the old literal string before writing the delta — code, SPEC, READMEs, skill docs, test fixtures. Missing one silently reintroduces the old default in docs even when the code is fixed; the same grep enumerates exactly what the spec delta must cover.

Related: [[hermetic-tmpdir-per-guard-case]] [[surgical-yaml-edits]]
