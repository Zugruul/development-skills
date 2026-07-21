---
tags: [review, orchestration, lifecycle]
paths: ["plugins/spec-workflow/scripts/next.py", "plugins/spec-workflow/scripts/guard-*.sh"]
strength: 1
source: "retro 2026-07-21 serial-delivery review"
graduated: false
created: 2026-07-21
---

Loop-infrastructure changes (pickers, guards, wait states) must be reviewed against RESTART and RESUME scenarios, not just steady-state: the highest-severity defect in the serial-delivery mode was a wait state that preempted resuming the session's own in-flight task — a deadlock invisible in every happy-path test but immediate on any interrupted session. Ask: "what does this print when the session comes back mid-task?"

Related: [[reproduce-then-verify-fix]]
