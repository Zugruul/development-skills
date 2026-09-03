---
tags: [briefing, verification, testing]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "PR#223 (MEM-012, #131) — caught a wrong SPG_README path (one dir level off) only after a full gate run; ls would have caught it in seconds"
graduated: false
created: 2026-07-19
---

When a test computes a path via `cd "$SOME_DIR/.." && pwd`, sanity-check with `ls` on the resulting path before trusting it in an assertion — a red gate run is a much slower feedback loop than a one-line `ls` and the mistake (wrong nesting level) is often invisible from reading the shell arithmetic alone.

Related: [[verify-cited-paths-from-repo-root]]
