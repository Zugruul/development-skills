---
tags: [bash, cli-design, error-handling]
paths: ["plugins/peer-review/scripts/*.sh"]
strength: 1
source: "PRV-001 (#167)"
graduated: false
created: 2026-07-15
---

Empty-diff short-circuit should happen BEFORE the missing-tool preflight check, not just before invoking the tool -- a repo with nothing to review shouldn't fail just because an optional external CLI (codex, gh, etc.) isn't installed. Order the checks: resolve diff first, then only preflight the downstream tool if there's actually something to hand it.
