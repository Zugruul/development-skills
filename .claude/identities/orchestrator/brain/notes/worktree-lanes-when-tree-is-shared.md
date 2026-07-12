---
tags: [concurrency, worktree, orchestration]
paths: []
strength: 1
source: "retro"
learned-from: PR #153 retro
graduated: false
created: 2026-07-11
---


# Give each task its own worktree when the main checkout is contested

When the human is live-editing the main checkout (uncommitted work present),
never run dev/review lanes on that checkout: branch switches strand agents,
force stash/restore gymnastics, and nearly cost human WIP. Create the lane as
a worktree off origin/<mainBranch> (`git worktree add .claude/worktrees/<id>`)
and brief the agent to do ALL work there with absolute-path `cd` per command.
Also true between agents: a reviewer and a dev sharing one tree drift into
each other between rounds.
