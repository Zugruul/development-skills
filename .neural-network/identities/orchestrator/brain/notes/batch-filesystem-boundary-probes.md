---
tags: [testing, review, efficiency, filesystem]
paths: ["plugins/**/*.py"]
strength: 1
source: "Task #277 post-merge interviews and independently reproduced boundary failures"
confidence: direct
graduated: false
created: 2026-10-19
last-touched: 2026-10-19
---

## Run a small boundary matrix before an expensive gate
For filesystem inventory work, cover parsing, path subprocess transport and final rendering together. Include non-UTF-8 filenames, CR/CRLF, trailing whitespace, malformed string scalars and a healthy sibling in both output formats.

## Preserve evidence
Commit regressions before fixes and replay historical failures in separate checkouts. If a new verified defect supersedes a running gate, stop only its verified process group, record the terminal status honestly and gate the new committed candidate.

Related: [[cheap-ab-before-10min-runs]] [[align-worktree-and-test-git-runtime]]
