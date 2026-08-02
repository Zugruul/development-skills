---
tags: [architecture, plugins, coupling, extensibility]
paths: ["plugins/spec-workflow/scripts/remote-capabilities"]
strength: 1
source: "task-524"
confidence: direct
graduated: false
created: 2026-08-02
last-touched: 2026-08-02
---

# Keep the engine domain-agnostic; ship domains as data bundles

When a generic engine grows its first concrete use case, the use case tends to
leak into the engine's directory even when it never leaks into the engine's
code. That structural signal is enough to invite real coupling later.

In task 524 the engine (remote-compute.py) contained zero ComfyUI code, but
comfy-run.py sat flat in scripts/ beside it. The fix: capability BUNDLES —
scripts/remote-capabilities/<name>/ holding capability.yaml (name, description,
payload, jobs with cmd templates + param patterns) plus payload scripts. The
engine installs a bundle, substitutes only its own placeholders ({capdir},
{jobdir}), and validates declared params.

Two guards keep it honest: a test that installs a FAKE bundle end to end, and a
test asserting the engine contains no domain-specific identifier. The second
one fired on a comment I wrote naming a specific tool inside the engine —
proving the guard works and that prose counts.

A second domain (SLM training) then shipped as a bundle with no engine edit.
