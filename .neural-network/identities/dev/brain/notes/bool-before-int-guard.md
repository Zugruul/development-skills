---
tags: [python, yaml, validation, types]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR-close #302 review evidence"
graduated: false
created: 2026-07-22
---

Python's isinstance(True, int) is True — every YAML int-field check must guard isinstance(val, bool) BEFORE isinstance(val, int), or enabled:true silently passes as a port/retainDays. Applied at all four int sites in assistant/config.py and verified by review; make it the default pattern for any new numeric config knob.

Related: [[extend-house-fixture-style]]
