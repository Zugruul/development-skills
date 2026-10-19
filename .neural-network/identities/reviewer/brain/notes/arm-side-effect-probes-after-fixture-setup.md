---
tags: [review, fixtures, git]
paths: ["plugins/spec-workflow/scripts/checkout_preflight.py"]
strength: 1
source: "Task #285 post-merge dev/reviewer interview"
confidence: direct
graduated: false
created: 2026-10-19
last-touched: 2026-10-19
---

## Separate fixture effects from command effects

- Configure a side-effect marker only after fixture setup is complete, or record/reset its setup state before invoking the command under review.
- A filesystem-monitor marker triggered by setup `git rm` does not prove that the later inspector invoked the monitor.
- Exercise the real command and compare the marker and repository snapshot across that invocation alone.

Related: [[fixture-provenance-check]] [[reproduce-before-verdict]]
