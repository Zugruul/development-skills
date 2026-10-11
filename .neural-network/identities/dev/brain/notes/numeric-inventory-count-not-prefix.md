---
tags: [tests, counts, oracles]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "#347 full gate SCANNED 40 failure and numeric boundary correction"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Compare Counts Numerically

- A substring assertion such as `SCANNED 3` is not an assertion that at least thirty files were scanned: it accepts three and fails when the inventory grows to forty.
- Parse the reported integer, compare the intended numerical bound, and keep the separate checks that prove the scan covered the right inventory.

## Boundary Cases

- Exercise below-threshold, threshold, next-decade and three-digit counts so growth cannot silently invalidate the oracle.

Related: [[deterministic-repro-fast]] [[batch-red-across-surfaces]]
