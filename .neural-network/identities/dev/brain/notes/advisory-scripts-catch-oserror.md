---
tags: [python, robustness, errors, http]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 2
source: "PR-close #312 (3rd recurrence)"
graduated: false
created: 2026-07-22
---

Advisory-only scripts (preflight, status probes, HTTP read endpoints) must catch the OSError CLASS around every filesystem read and every state write. THIRD recurrence: history() caught only FileNotFoundError, so a chmod-000 transcript propagated PermissionError and dropped the whole HTTP response. The pattern to grep in review: any 'except FileNotFoundError:' on a read path is a smell — the broad-but-honest form is 'except OSError as e:' + a warning field. Reads → enumerated warning/FAIL line; writes → degrade, still report.
