---
tags: [testing, installer, fixtures]
paths: ["plugins/remote-compute/tests/**"]
strength: 1
source: "development-skills#108 local gate and independent review"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Verify the published payload
- Capture the staged files before an installer removes its temporary source.
- Assert exact destination, complete inventory, content hashes, symlink policy and line-ending normalization.
- A temporary source-directory name is an implementation detail, not the installation contract.
- Challenge the checker with missing, extra, duplicate and corrupt evidence; verify source bytes remain unchanged.

Related: [[capture-real-output-as-fixtures]] [[bash-test-sections-shared-state]]
