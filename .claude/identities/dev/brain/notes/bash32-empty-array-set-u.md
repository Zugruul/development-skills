---
tags: [bash, portability, test-coverage]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "post-merge breakage of brain.sh, PR#4"
graduated: false
created: 2026-07-07
---

Empty bash arrays + set -u fail on macOS bash 3.2 when expanded as ${arr[@]} — guard with ${arr[@]+...} or avoid arrays. Cover the DEFAULT (flag-less) invocation path in tests; the always-with-flags path hid this.

Related: [[budget-count-join-separators]]
