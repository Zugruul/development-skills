---
tags: [refactoring, python]
paths: ["plugins/spec-workflow/scripts"]
strength: 1
source: "retro AST-020 (dev interview)"
graduated: false
created: 2026-07-22
---

After a delegate-to-new-module refactor, grep the source module for now-dead imports and constants — Python never fails loudly on an unused import, so the dead surface survives review unless explicitly hunted. Make it the refactor's final mechanical step.
