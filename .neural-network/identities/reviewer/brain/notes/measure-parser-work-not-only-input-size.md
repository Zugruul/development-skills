---
tags: [review, performance, python, regex]
paths: ["plugins/spec-workflow/scripts/assistant/remote_audit.py"]
strength: 1
source: "issue-349-review-limit"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Risk
An input-size limit and bounded JSON decode attempts do not bound a regex scan that runs first. Repeated unsuccessful matches can monopolize Python's GIL even in a background worker.

## Probe
Exercise supported-size inputs that contain many candidate token starts but no delimiter. Run a same-process heartbeat alongside projection and bound the whole experiment with a subprocess timeout.

## Review
Measure both total work and heartbeat gaps. Check a candidate correction against valid dashed assignments and credential redaction. Do not equate passing functional cases with responsiveness.

Related: [[reproduce-before-verdict]] [[reports-are-not-the-code]]
