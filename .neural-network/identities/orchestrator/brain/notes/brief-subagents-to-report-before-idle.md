---
tags: [briefing, subagents]
paths: ["**"]
strength: 2
source: "PR#140 MEM-032 feedback triage"
graduated: false
created: 2026-07-16
---

A subagent brief needs an explicit line telling the agent to SendMessage its final report back before going idle -- a DELIVERABLE section describing what to produce is not the same instruction as when/how to deliver it, and its absence causes silent idling that costs a manual nudge round-trip per agent.

Recurrence (MEM-032, PR#140): happened 3+ times in one iteration -- the dev agent's own backgrounded full-gate run, and all three agents' retro-interview answers on the first ask -- each required an explicit re-prompt after an idle notification before the actual content arrived. Confirms this is a recurring pattern worth a standing habit, not a one-off brief gap: even a direct question (the retro interview) triggered the same silent-idle behavior, not just a backgrounded long-running command.

Related: [[nudge-idle-agents-after-backgrounded-gate]]
