---
tags: [gate, triage, worktrees]
paths: ["plugins/spec-workflow/tests"]
strength: 1
source: "retro 373/AST-020 (feedback item 1)"
graduated: false
created: 2026-07-22
---

A red gate on a task branch gets reproduced on a throwaway clean-mainline worktree BEFORE any blame lands on the diff. Identical failure on clean main = a pre-existing or environmental regression: file it as its own top-priority hotfix task, keep the original task lane unblocked, and merge the hotfix first so the task branch can record a green gate on top of it.

Related: [[shell-plumbing]]
