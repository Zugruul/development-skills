---
tags: [briefing, subagents]
paths: ["**"]
strength: 1
source: "task #163 retro, 2026-07-12"
graduated: false
created: 2026-07-16
---

A subagent brief needs an explicit line telling the agent to SendMessage its final report back before going idle. A DELIVERABLE section describing what to produce is not the same instruction as when/how to deliver it, and its absence causes silent idling that costs a manual nudge round-trip per agent.
