---
tags: [tests, bash, lifecycle, ports]
paths: ["plugins/spec-workflow/tests/_lib.sh", "plugins/spec-workflow/tests/section-whisper-sidecar.sh"]
strength: 2
source: "issue-541 round-1 merged; recurrence of issue-349-review-limit"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-18
---

## Failure mode
A selector called through command substitution runs in a child shell. Updating its used-port list does not reserve an unbound sibling in the parent. A lifecycle wrapper can reintroduce collisions by discarding an exclusion that the selector already supports.

## Preserve the exclusion
Pass configured sibling ports through every wrapper and every startup attempt. Bound allocation retries and check allocation success before exporting a port or dispatching a command. Keep existing calls without an exclusion working.

## Verify the boundary
Use equal-seed draws through the real selector and execute actual caller expressions to expose omitted arguments. For initial and retry exhaustion, check the exact failure counters, retained destination value and absence of extra dispatch. Bound probes with an existing runtime rather than adding a platform-specific executable.

Related: [[deterministic-repro-fast]] [[bash-test-sections-shared-state]]
