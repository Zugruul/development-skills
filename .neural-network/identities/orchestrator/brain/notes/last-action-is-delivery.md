---
tags: [agents, protocol]
paths: ["**"]
strength: 1
source: "session feedback 2026-07-08 (3 of 4 reviewers idled without reporting)"
graduated: false
created: 2026-07-08
---

Every spawned agent prompt must state that its FINAL action is delivery — "your LAST action must be SendMessage to main with the verdict/report" — not merely task completion. An agent that finished the analysis but not the report has not finished; the two reviewers whose prompts lacked the line both went idle silently and needed a nudge, the two whose prompts had it reported unprompted.
