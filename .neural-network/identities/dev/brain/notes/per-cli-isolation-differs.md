---
tags: [cli, isolation, auth, adapters]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "PR-close #310"
graduated: false
created: 2026-07-22
---

Isolation mechanisms are per-CLI, not copy-paste: codex needed an isolated env home (auth is a portable file) while claude must NOT get one (isolated CLAUDE_CONFIG_DIR logs you out — auth is not a portable file there); claude offers --tools "" (a full tool disable, stronger than codex sandbox) and --safe-mode. Research each CLI's auth locus AND instruction-ingestion locus separately; document rejected mechanisms with the evidence, not just chosen ones.

Related: [[env-home-isolation-not-cwd]] [[probe-isolation-claims-on-real-cli]]
