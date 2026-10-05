---
tags: [bash, python, selection-logic, bug]
paths: []
strength: 1
source: "#197 -- reviewer-197 caught a real cache-version-selection bug"
graduated: false
created: 2026-07-16
---

When designing a 'pick the right one of several similar installed copies' selection strategy, a naive lexicographic sort of version-like strings is almost never correct (semver doesn't sort lexicographically -- '0.9.0' vs '0.25.0' vs '0.1.0' don't order the way a human expects, and even when they happen to, it's not actually load-bearing on version semantics). Prefer an explicit signal of what's actually active (an env var the real resolution mechanism sets) with a real recency signal (mtime) as fallback -- never string-sort order dressed up as a selection strategy.
