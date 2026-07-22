---
tags: [git, shared-clone, safety, review-process]
paths: ["**"]
strength: 1
source: ""
confidence: direct
learned-from: GL-020 #255 review incident
graduated: false
created: 2026-07-22
last-touched: 2026-07-22
---

In a shared clone, a bare `git stash pop` popped a PRIOR SESSION's stash (touching the same tracked runtime files) instead of the one just created — the intended second stash never ran because a mid-chain command was permission-denied and silently no-op'd. Rules: (1) stash only with an explicit message (`git stash push -u -m "<task>-tmp"`) and pop by the matched ref, never bare pop; (2) verify each chained command actually executed (output/exit code) before running a follow-up that assumes it did; (3) never reproduce a historical red state by checkout/stash mutation of a live shared clone — read the test commit's diff, or use an isolated worktree. Reviewer sessions must not mutate the working tree at all.
