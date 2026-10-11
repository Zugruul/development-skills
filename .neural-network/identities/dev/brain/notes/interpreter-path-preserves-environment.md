---
tags: [python, venv, installer, argv]
paths: ["plugins/spec-workflow/scripts/assistant/**"]
strength: 1
source: "#347 round 1 venv reproduction and round 2 independent verification"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Preserve Interpreter Identity

- An interpreter's symlink path can select its virtual environment. Resolving it to the base binary can silently remove that environment's dependencies.
- Bind the absolute executable path without resolving its symlinks. Resolve engine code independently when the contract requires a canonical code path.

## Verify the Installed Command

- Create a real symlink virtual environment with an environment-local dependency.
- Execute generated check and invoke commands from an unrelated cwd; assert both `sys.prefix` and the dependency source.
- Keep copied-interpreter and spaced-path controls.

Related: [[capture-dont-transcribe]] [[deterministic-repro-fast]]
