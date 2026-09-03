---
tags: [review, docs, verification]
paths: ["plugins/spec-workflow/README.md"]
strength: 1
source: "retro MEM-030 (review rounds)"
graduated: false
created: 2026-07-23
---

Two high-yield reviewer habits: FIRST grep the covenant docs (README/spec) for every new user-facing name in the diff (script names, env vars, subcommands) — a missing entry is a mechanical, blocking find before any code is read. SECOND, when a diff claims environment-coupled test behavior (absence pins, hermeticity fixes), execute those tests in the real current environment state instead of reasoning about them — a pin proven load-bearing against the live machine beats any argument from the diff text.

Related: [[reproduce-red-first-claims]] [[execute-guarantees-adversarially]]
