---
tags: [tests, flakes, tmpdir, ci]
paths: ["plugins/spec-workflow/tests/**"]
strength: 1
source: "#412 root cause"
graduated: false
created: 2026-07-26
last-touched: 2026-07-26
---

Full-suite failures that appear only late in a long multi-agent session and only in FULL ordered runs point at shared-$TMPDIR accumulation: thousands of stale mktemp dirs from sibling lanes degrade fixture-heavy sections deterministically. Diagnose with an A/B: same suite, fresh TMPDIR=$(mktemp -d) — green proves the mechanism (proven 2026-07-26; permanent fix #412 gives every run a private tmp root; on macOS bare mktemp IGNORES $TMPDIR, so a shim is load-bearing).

Related: [[check-concurrent-suites-before-believing-red]] [[hermetic-path-fixtures-for-cli-tests]]
