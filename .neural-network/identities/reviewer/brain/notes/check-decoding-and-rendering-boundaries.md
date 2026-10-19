---
tags: [review, python, unicode, filesystem]
paths: ["plugins/**/*.py"]
strength: 1
source: "Task #277 post-merge interviews and independently reproduced boundary failures"
confidence: direct
graduated: false
created: 2026-10-19
last-touched: 2026-10-19
---

## Follow the value through every boundary
A parsed value can survive loading and exception handling but still fail subprocess decoding or output encoding. Review those boundaries independently; one tolerant handler does not protect the whole command.

## Drive the actual output path
Use a malformed scalar and a valid sibling in each output mode. For path-valued subprocess results, combine unusual bytes with CR/CRLF and trailing whitespace, then assert the exact resulting filename bytes. Replay each regression at its tests-only commit.

Related: [[reports-are-not-the-code]] [[reproduce-before-verdict]]
