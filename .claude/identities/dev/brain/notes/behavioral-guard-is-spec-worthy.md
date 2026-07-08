---
tags: [spec-delta, contracts]
paths: ["docs/spec-deltas/**", "SPEC.md"]
strength: 1
source: "PR#64 (#62) retro — scope call ratified by orchestrator"
graduated: false
created: 2026-07-07
---

A guard/check with externally observable behavior (fails a command, changes an exit code, emits a contract message) is a spec contract, not an implementation detail — give it its own EARS requirement in the delta even when the brief only asked for the narrower change. Docs-only statements are for process rules with no runtime surface.

Related: [[old-path-repo-wide-sweep]]
