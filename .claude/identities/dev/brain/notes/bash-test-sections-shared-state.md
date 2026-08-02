---
tags: [testing, bash, harness, flakiness]
paths: ["plugins/spec-workflow/tests/section-remote-compute.sh"]
strength: 1
source: "task-524"
confidence: direct
graduated: false
created: 2026-08-02
last-touched: 2026-08-02
---

# Shared shell state between checks is a test-harness bug generator

In sourced bash test sections, two failure modes bit repeatedly while writing
section-remote-compute.sh:

1. **$out clobbering.** Inserting a new block between an assignment and the
   checks that consume it silently breaks those checks — they now assert
   against the NEW output. Happened twice. Insert new blocks AFTER every check
   that reads the current $out, or use a distinct variable.

2. **Leaked state across sections.** A dispatch test took the cooperative lock
   under holder "bob" and never released it, so later sections failed with
   LOCKED for unrelated reasons. Similarly, a fake transport arm that reports a
   job as permanently running poisons every later concurrency check.

Rule: any test that mutates shared state (locks, registry entries, fake
transport arms) must restore it in the same block. Prefer asserting on a
freshly captured variable over a long-lived one.
