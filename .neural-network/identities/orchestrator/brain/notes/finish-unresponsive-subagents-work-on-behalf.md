---
tags: [briefing, merge, efficiency]
paths: ["**"]
strength: 1
source: "PR#233 (CDX-031, #188) -- dev-cdx031 went silent after 2 pings; its uncommitted work was already complete and verified, finished + committed on-behalf rather than waiting further"
graduated: false
created: 2026-07-19
---

When a dev subagent goes unresponsive after 2+ status pings but its uncommitted working-tree changes are already complete and independently verifiable (the test passes standalone, matches the brief's design exactly), finish the task yourself: verify it works (run the relevant section + full gate), commit on-behalf of the dev identity (identity.sh on-behalf dev), push, open the PR, and send the subagent a courtesy note in case it later revives (so it doesn't push conflicting work). Don't wait indefinitely on a silent agent when the work itself is already done and verifiable -- silence isn't the same as absence of progress.

Related: [[fix-trivial-review-nits-directly-on-behalf]]
