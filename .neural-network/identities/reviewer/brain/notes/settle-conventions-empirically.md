---
tags: [review, style, verification]
paths: ["plugins/spec-workflow/**"]
strength: 1
source: "PR-close #301 reviewer interview"
graduated: false
created: 2026-07-22
---

Settle style/convention questions empirically in one line, never by eyeballing two files: e.g. 'for f in scripts/*.py; do head -1 $f; done | sort | uniq -c' answers the shebang convention across the whole codebase at once. Cheap, decisive, and removes convention findings that are really guesses.

Related: [[import-and-probe-python-library]]
