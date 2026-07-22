---
tags: [git, concurrency, hotfix, parallel-sessions]
paths: ["**"]
strength: 1
source: "PR-close #301 / bug #359 incident"
graduated: false
created: 2026-07-22
---

Before filing or lane-fixing a repo-wide breakage discovered from a snapshot, git fetch and re-verify on the CURRENT remote tip — a parallel session may already have fixed it. Bug #359 was filed and fixed in a stale lane while origin/main (2c82559) already carried the identical fix; the independent reviewer caught that the stale branch would have REGRESSED main's better wording. Cost of the check: seconds. Also generalizes: recurring red-gate signatures in .claude/lessons.jsonl mean main itself is broken — check there first.

Related: [[idle-agent-is-not-done]]
