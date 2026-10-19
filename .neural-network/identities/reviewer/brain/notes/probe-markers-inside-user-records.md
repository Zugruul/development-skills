---
tags: [review, parsing, preservation]
paths: ["**/*.sh", "**/*.py"]
strength: 1
source: "Task #274 independent review and runtime audit"
confidence: direct
graduated: false
created: 2026-10-19
last-touched: 2026-10-19
---

## Challenge marker boundaries
When a helper replaces a marked region, test whether its parser recognizes a marker inside user-owned data. Byte-oriented input does not guarantee byte preservation: a generic line splitter can introduce boundaries the file format does not have.

## Independent evidence
Compare baseline and candidate output for the same adversarial bytes. Check both the retained bytes and the consumer's behavior, such as git check-ignore. A successful exit can accompany silent deletion.

Related: [[reproduce-before-verdict]] [[reports-are-not-the-code]]
