---
tags: [testing, fixtures, hermeticity]
paths: ["plugins/spec-workflow/scripts/assistant/gates.py", "plugins/spec-workflow/tests"]
strength: 1
source: "retro 373/AST-020 (dev interviews + incident)"
graduated: false
created: 2026-07-22
---

A fixture that spawns a server (or any subprocess with discovery/scan behavior) must pin EVERY implicit search path — scan bases, HOME-derived defaults, config lookups — to isolated fixture-owned roots; a suite that claims hermeticity needs a regression test simulating a polluted developer machine, because environment-coupled defaults only break on machines whose state changed. Corollary: an env override used to steer one lookup (faking HOME) leaks sideways into unrelated resolution in the subprocess (site-packages, import machinery, caches) — explicitly pass through the real paths the subprocess's imports need.

Related: [[test-section-shell-plumbing-risk]] [[inspect-red-before-trusting]]
