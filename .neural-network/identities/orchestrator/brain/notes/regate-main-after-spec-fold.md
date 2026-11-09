---
tags: [spec-fold, gate, release, tests]
paths: ["docs/spec-deltas/**", "plugins/spec-workflow/tests/**"]
strength: 1
source: "Zugruul/development-skills#570"
confidence: direct
graduated: false
created: 2026-11-09
last-touched: 2026-11-09
---

# Re-run the gate on main after a spec fold, before releasing

The fold step moves every applied delta from docs/spec-deltas/<n>.md to docs/spec-deltas/applied/<n>.md. Tests written on the task branch often read the pending path, so they pass on the branch and fail on main as soon as the fold lands. In #560-#567 the fold (17be4ea) went out in release 0.77.0 without a fresh gate and broke 11 checks on main (#570).

- Gate main after the fold commit, before the release bump, as you would after any commit that moves files.
- In briefs, tell devs to read deltas with `delta_body <n>` from tests/_lib.sh (pending, else applied/), never with a direct `cat` of the pending path.
