---
tags: [process, testing, flakiness]
paths: []
strength: 1
source: "PR#214 (CDX-030) iteration; wrongly cross-referenced #208"
graduated: false
created: 2026-07-18
---

When a full-suite gate run fails on tests unrelated to the diff's subject matter, don't assume "known host-load flakiness" (even when a matching tracked issue like #208 exists) without first bisecting: run the SAME suite at the SAME moment in a fresh worktree on main vs. a fresh worktree on the branch. If main is clean and the branch isn't, it's a real regression in the branch, not ambient load -- even if the failure set looks deterministic and load happens to be elevated at the time (a real bug and elevated load can coincide). I posted a wrong cross-reference on #208 before doing this bisect, misdirecting anyone else chasing that issue; had to post a correction. The actual bug (a missing subshell around a fixture's `cd`, corrupting cwd for every later-sourced test section) was mine, unrelated to #208's real root cause. Related: [[fix-root-cause-not-retry-around-flake]].
