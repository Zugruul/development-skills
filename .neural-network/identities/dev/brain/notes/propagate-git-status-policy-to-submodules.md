---
tags: [git, submodules, testing]
paths: ["plugins/spec-workflow/scripts/checkout_preflight.py"]
strength: 1
source: "Task #285 post-merge dev/reviewer interview"
confidence: direct
graduated: false
created: 2026-10-19
last-touched: 2026-10-19
---

## Include subordinate Git configuration

- A parent `status --untracked-files=all` does not necessarily override a submodule's own hidden-untracked preference.
- Pass an inherited `-c status.showUntrackedFiles=all` when the contract requires every untracked change, alongside `--ignore-submodules=none`.
- Verify untracked, tracked and committed submodule changes in real repositories with hiding preferences enabled.

Related: [[acceptance-criterion-outranks-test-spec-paraphrase]] [[capture-dont-transcribe]]
