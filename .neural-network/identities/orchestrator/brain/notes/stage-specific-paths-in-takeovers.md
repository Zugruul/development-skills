---
tags: [git, takeover, hygiene]
paths: ["**"]
strength: 1
source: "PR-close #314 incident"
graduated: false
created: 2026-07-22
---

In take-overs never git add -A: a stray artifact (.gate-run.log from a backgrounded gate) got swept into a commit and needed an amend. Stage the exact files the diff review covered; anything else in the tree is either lane noise to discard or a surprise to investigate.

Related: [[unresponsive-agent-take-over]] [[idle-agent-is-not-done]]
