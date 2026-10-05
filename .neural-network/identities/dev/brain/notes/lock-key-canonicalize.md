---
tags: [python, concurrency, flock, paths]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "PR-close #304 review r2"
graduated: false
created: 2026-07-22
---

Any dict keyed by a filesystem path for resource identity (locks, reentrancy counters, caches) must canonicalize with os.path.realpath first — relative/absolute/symlink/trailing-slash spellings of the SAME directory otherwise key separately, and for flock-style reentrancy that means a true self-deadlock (flock binds to the open-file-description, not the pid). Pair with try/except around the post-open acquisition so the fd never leaks on failure.

Related: [[marker-barrier-interleave]] [[bool-before-int-guard]]
