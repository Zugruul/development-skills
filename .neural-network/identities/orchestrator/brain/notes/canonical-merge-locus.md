---
tags: [merge, git, worktrees]
paths: ["**"]
strength: 1
source: "retro session 2026-07-23"
graduated: false
created: 2026-07-23
---

Under local-route delivery, use ONE canonical merge procedure every time: squash-merge in a dedicated detached temp worktree and push the result BY SHA to the remote mainline (git push origin <sha>:main). Never force-move the local mainline branch — it is frequently checked out somewhere (primary clone, another worktree) and branch -f either fails or silently desyncs a checkout; and never commit follow-ups (retro, docs) without first confirming the current base is the pushed mainline tip, or the commit needs a cherry-pick transplant.

Related: [[clean-main-repro-before-blame]] [[search-branches-before-reimplementing]]
