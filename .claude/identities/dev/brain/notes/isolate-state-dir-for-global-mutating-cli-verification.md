---
tags: [testing, cli, isolation, codex]
paths: []
strength: 1
source: "task #176 (CDX-004)"
graduated: false
created: 2026-07-16
---

When an acceptance criterion requires exercising a CLI command that mutates persistent global state (writes to a real config file outside the repo), isolate via the tool's own home/config env override rather than either skipping verification or running it against the real machine.

Why: #176 (CDX-004) needed to prove `codex plugin marketplace add` + `codex plugin list` actually enumerate the new manifest correctly. Redirecting via `CODEX_HOME` (the same pattern as `GIT_DIR`/`XDG_CONFIG_HOME`/`KUBECONFIG` elsewhere) into a throwaway dir gave a real end-to-end roundtrip with zero risk to the developer's actual ~/.codex/config.toml. Isolation had a second-order payoff too: because the run was known to never touch the real config, a stray unrelated global marketplace entry found during review could be conclusively proven pre-existing (git-sourced, hours-older mtime) rather than something this task created -- that provenance call is only decidable when you know your own run was isolated.

How to apply: before running any CLI whose side effect isn't contained to the repo/worktree, check for a state-dir override env var; use a fresh temp dir, run the full roundtrip, capture real output, `rm -rf` after. Keep the hermetic test suite scoped to the artifact's own shape (schema/content assertions); treat the live global-state roundtrip as a recorded manual verification step, not something the automated suite runs on every machine.
