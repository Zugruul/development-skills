---
tags: [briefing, background-tasks]
paths: ["**"]
strength: 1
source: "PR#224 (CDX-012, #182) -- dev-cdx012 and pr-reviewer-pr224 both independently misread a slow gate run as dead"
graduated: false
created: 2026-07-19
---

Both the dev agent and the independent reviewer, in the SAME iteration, independently misread a slow background gate run as died/hung and went idle without reporting instead of waiting for the actual completion signal -- the same failure mode twice is a signal the BRIEF should say it explicitly, not just something each agent has to learn on its own. When briefing a subagent that will run a command likely to exceed the foreground timeout (this repo's full test suite routinely does), tell it up front: "if you background this, wait for the actual completion notification/exit code before concluding success or failure -- do not read a possibly-still-buffering log file early and report a false failure."

Related: [[trust-completion-signal-not-early-log-read]]
