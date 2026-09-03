---
tags: [cli, isolation, env, security, codex]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "PR-close #309 review r1"
graduated: false
created: 2026-07-22
---

cwd isolation does not cover env-home config: CLIs read global instruction/config files from $HOME-style env dirs ($CODEX_HOME/AGENTS.md) REGARDLESS of -C/working-dir isolation — the boundary must override the env home itself, carrying only the credential file (copy, never symlink, so cleanup cannot touch the real secret). Prove isolation with the real CLI: codex debug prompt-input renders the exact model-visible context WITHOUT auth — the standard no-cost probe for what actually travels.

Related: [[getter-over-global-snapshot]] [[advisory-scripts-catch-oserror]]
