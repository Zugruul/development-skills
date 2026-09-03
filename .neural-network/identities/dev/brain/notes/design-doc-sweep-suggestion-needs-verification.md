---
tags: [testing, design-docs]
paths: ["plugins/spec-workflow/tests/*.sh"]
strength: 1
source: "PR#226 (CDX-013, #183) -- cdx-E1.md's suggested !` sweep collided with seed-board's explicitly out-of-scope false positive"
graduated: false
created: 2026-07-19
---

A "belt-and-suspenders repo-wide sweep" pattern suggested in a design doc (e.g. a literal grep for an old syntax) isn't automatically zero-hit-safe just because it looks obviously correct -- it can collide with an explicitly-named out-of-scope false positive elsewhere in the repo (here: a naive `grep '!\`'` matched both the real Claude-CLI command-substitution sites AND an unrelated line that happened to contain the same two-char substring while explaining something else entirely). Always test the design doc's OWN suggested check against the real out-of-scope sites before trusting it, and narrow the pattern (e.g. requiring the substitution to be followed by a command-word character) rather than either widening scope to "fix" the false positive or silently accepting a non-discriminating sweep.

Related: [[old-path-repo-wide-sweep]]
