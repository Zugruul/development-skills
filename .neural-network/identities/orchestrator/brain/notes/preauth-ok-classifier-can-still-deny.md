---
tags: [merge, permissions, auto-review]
paths: ["plugins/spec-workflow/skills/build-next/**"]
strength: 1
source: "PR#61 (#60) merge"
graduated: false
created: 2026-07-07
---

merge-mode.sh preauth "ok" is advisory: the auto-mode permission classifier can still deny gh pr review/merge (e.g. flagging orchestrator-posted approval of its own subagent's PR as self-approval). The correct move is never to retry around it — surface it to the human (AskUserQuestion), get explicit per-artifact direction, and state the consent model in the iteration report.

Related: [[board-out-of-compound-commands]]
