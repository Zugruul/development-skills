---
tags: [review, git, staleness]
paths: ["**"]
strength: 2
source: "bug #359 review"
graduated: false
created: 2026-07-08
---

Always diff a branch two-dot against the CURRENT fetched origin/main (git fetch first; git diff origin/main..HEAD), never only three-dot against the merge-base — a stale branch can look clean while actually reverting work main has since landed. Caught live on bug #359: the branch's 'fix' would have regressed main's already-landed better version; merge-base diffing alone would never have shown it.
