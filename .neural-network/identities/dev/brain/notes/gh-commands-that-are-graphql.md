---
tags: [github, quota, api]
paths: ["plugins/spec-workflow/scripts/**"]
strength: 1
source: "#560-#567 reviews"
confidence: direct
graduated: false
created: 2026-11-09
last-touched: 2026-11-09
---

`gh issue comment`, `gh issue create`, `gh pr list` and `gh project` all spend GraphQL points; `gh api repos/...` REST calls do not.

## What happened
- In one set, four separate lanes posted comments or listed PRs through GraphQL commands while claiming REST, and reviewers caught each one.

## What to do
- Use `gh api -X POST repos/R/issues/N/comments -F body=@file` for comments, and `gh api repos/R/pulls?state=...` for PR lists.
- Make tests assert the exact call shape and count with an exact comparison, not a substring match.
