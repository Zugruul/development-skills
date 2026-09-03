---
tags: [contracts, templates, testing, integration]
paths: ["plugins/spec-workflow/scripts/remote-compute.py"]
strength: 1
source: "task-524"
confidence: direct
graduated: false
created: 2026-08-02
last-touched: 2026-08-02
---

# A documented placeholder nobody substitutes is a silent breakage

remote-compute documented {jobdir} as an engine-supplied placeholder, shipped a
bundle manifest that used it, and never substituted it: only declared params
were replaced, so the literal string "{jobdir}" reached the remote shell.

It survived because the hermetic tests asserted on params (which ARE
substituted) and the live runs used a bundle that happened to also read
$COMPUTE_JOB_DIR from the environment. A parallel agent building the second
bundle hit it and worked around it, which is how it surfaced.

Rules:
- Every documented placeholder needs a test asserting the LITERAL never
  reaches the payload (check_absent on the transport log, not just a positive
  check on the resolved value).
- When a second consumer works around your contract instead of using it, treat
  the workaround as a bug report about the contract.
