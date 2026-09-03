---
tags: [review, tdd, git]
paths: ["plugins/spec-workflow/**"]
strength: 3
source: "PR#128 MEM-004 retro"
graduated: false
created: 2026-07-07
---

Verify a red-first TDD claim by running the full suite at the red commit inside an isolated `git worktree add` -- never `git checkout <sha> -- <path>` into the current tree. Diff the failure set against HEAD's green run: exactly-the-new-checks failing rules out both a vacuous test and a hidden pre-existing regression.

Recurrence (MEM-004 review): checked out the red commit (3b9a4f7) in an isolated worktree and DIRECTLY EXECUTED `git check-ignore .claude/feedbacks/feed.yaml` to confirm rc=0 (ignored) at that commit -- turning "the commit message says this was red" into "I ran the exact assertion and got the failing result myself." A commit message claiming redness is itself just a claim (same failure family as reports-are-not-the-code) -- this is the standard-strength verification for ANY red-first TDD claim, not an optional extra: lighter checks (git show --stat to confirm scope, diffing test content) verify scope, not redness -- those are different questions and both need independent verification.

Related: [[recompute-hashes-never-eyeball]] [[reports-are-not-the-code]]
