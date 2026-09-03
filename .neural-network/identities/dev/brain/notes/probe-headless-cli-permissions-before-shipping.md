---
tags: [adapters, permissions, sandbox, testing]
paths: ["plugins/spec-workflow/scripts/assistant/*.py"]
strength: 1
source: "loop-feedback 2026-07-29 (batch 2)"
confidence: direct
graduated: false
created: 2026-07-29
last-touched: 2026-07-29
---

A headless CLI's sandbox has THREE independent gates and documentation reasoning alone predicts none of them reliably: (1) enabling a tool (--tools) does NOT allowlist it for permission checks (--allowedTools does), (2) permission-mode auto-accepts only apply where a prompt could have appeared, and (3) a path-sensitivity classifier can veto specific targets (e.g. anything .claude-nested) regardless of every flag. Before shipping any adapter flag-set change, run ONE cheap live probe -- smallest model, trivial prompt, then inspect the actual side effect on disk -- it settles in minutes what code review argued about for longer. Proven 2026-07-29: the shipped write-enable could never work; the probe found the working shape (write to the isolated cwd, engine publishes after the turn) immediately.
