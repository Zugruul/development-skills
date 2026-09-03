---
tags: [review, security, shell-injection]
paths: []
strength: 1
source: "PRV-002 review (reviewer-prv002)"
graduated: false
created: 2026-07-15
---

When a subagent's hardcoded security-critical flag (e.g. --sandbox read-only) is the whole point of the task, verify it by grepping for the literal invocation string in the final diff -- not by trusting a prose claim in the agent's own report. A prompt-injection-adjacent risk to also check explicitly: does any user-controllable string (a --label override, a diff's own content) ever get shell-interpolated near the exec call, vs. passed through an env var / subprocess arg boundary that can't be reinterpreted as shell syntax.
