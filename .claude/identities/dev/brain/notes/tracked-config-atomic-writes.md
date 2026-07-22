---
tags: [python, yaml, concurrency, config]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR-close #305 review r2"
graduated: false
created: 2026-07-22
---

Any TRACKED config file a script mutates (project.yaml, manifests) needs the same discipline as brain files: one read → compose fully in memory → parse-validate the composed text → ONE same-dir mkstemp+os.replace write under a flock; and decide-then-write beats write-then-revert (a malformed input is refused before any byte changes). Torn tracked-config files are worse than lost updates — they break every future parse.

Related: [[lock-key-canonicalize]] [[marker-barrier-interleave]]
