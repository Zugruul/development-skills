---
tags: [python, validation, yaml]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#53 retro"
graduated: false
created: 2026-07-08
---

isinstance(True, int) is True in Python — any bounds check on an integer config key needs an explicit isinstance(val, bool) exclusion BEFORE the int check, or YAML `true` silently satisfies "val >= 1". Pin bool and float-equals-int as SEPARATE fixtures: a plausible loosening to isinstance(val, (int, float)) is only caught by the float case.

Related: [[stdlib-vs-enrichment-split]]
