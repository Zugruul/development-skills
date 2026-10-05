---
tags: [testing, fixtures]
paths: ["plugins/spec-workflow/scripts/*.py", "plugins/spec-workflow/tests/*.sh"]
strength: 1
source: "PR#225 (MEM-013, #132) -- mem013 rule legitimately broke cases d/h/k's no-op assumption; fixed by pre-seeding their .gitignore"
graduated: false
created: 2026-07-19
---

When adding a new detection rule to a system with existing "expect no-op" fixtures (e.g. a new sync-configs.py rule alongside project.yaml text rules), the new rule can retroactively break those fixtures' no-op assumption if their setup never accounted for the NEW thing being checked (e.g. pre-existing fixtures never seeded a .gitignore, so a new gitignore-reconciliation rule legitimately started firing on them). This isn't a bug in the new rule -- it's the fixtures now needing to be genuinely inert with respect to every rule, not just the one they were written to test. Catch it by running the FULL existing test section (not just your new cases) after implementing, and fix affected fixtures' setup in the same PR.

Related: [[old-path-repo-wide-sweep]]
