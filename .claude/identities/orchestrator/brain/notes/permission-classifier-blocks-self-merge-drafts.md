---
tags: [permissions, merge, review]
paths: []
strength: 2
source: "feedback item 0, 2026-07-10T06:55:00Z"
graduated: false
created: 2026-07-10
---

The permission system blocks converting your own self-authored draft PR to
ready and merging it in the same action whenever there's no visible human
review step. The consent bar has gradations: a generic "merge PRs"
instruction is insufficient, and even a direct "okay, merge it please" can
still be insufficient. Only an instruction that explicitly names the
specific thing being bypassed ("merge the unreviewed draft PR", "skip
review and merge") clears it. When blocked, tell the human the exact
phrasing that would satisfy consent rather than silently retrying the same
denied action with minor rewording.
