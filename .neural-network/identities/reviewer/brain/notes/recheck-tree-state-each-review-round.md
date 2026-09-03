---
tags: [review, worktree]
paths: []
strength: 1
source: "retro"
learned-from: PR #153 retro
graduated: false
created: 2026-07-11
---


# Re-verify branch + cleanliness at the start of every review round

A shared working directory drifts between review rounds — other agents or the
human may have switched branches or left uncommitted work. At the start of
each round: check `git branch --show-current` and `git status` before
trusting file state or git log. If unrelated uncommitted work is present,
stash it, do the round, restore it exactly — and say so in the report.
