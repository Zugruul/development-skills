---
tags: [python, filesystem, subprocess, tdd]
paths: ["plugins/**/*.py"]
strength: 1
source: "Task #277 post-merge interviews and independently reproduced boundary failures"
confidence: direct
graduated: false
created: 2026-10-19
last-touched: 2026-10-19
---

## Treat paths as filesystem data
Read subprocess output as bytes when it represents a path. Remove only the protocol terminator, then use filesystem decoding. Text mode can normalize CR/CRLF; stripping whitespace can change a valid filename.

## Prove the round trip
Exercise the real CLI with non-UTF-8 bytes, trailing spaces, CR and CRLF. Compare `os.fsencode()` values, test every renderer, and retain a healthy sibling beside invalid data.

Related: [[batch-red-across-surfaces]] [[capture-dont-transcribe]]
