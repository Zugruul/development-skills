---
name: review-lane
description: Starts a second Herdr agent next to an existing worktree lane to run the peer-review skill on that lane's diff, and brings the findings back without applying them. Use for '/herdr-development-skills:review-lane', 'get a second opinion on the lane for issue 123', 'review that worktree in another agent'. Requires Herdr, the herdr plugin and the peer-review plugin.
allowed-tools: Bash, AskUserQuestion
---

# An independent review next to a lane

Run `python3 "../../scripts/detect.py"` first (path relative to this `SKILL.md`). Continue only when `review-lane` is `READY`; otherwise relay the reasons and stop. This skill needs only Herdr and peer-review; it works without spec-workflow.

Treat the rest of the request as: which lane (a worktree, branch, workspace or lane agent) and optionally the reviewing agent's kind.

## 1. Find the lane

Use the `herdr:status` skill. If the request could mean more than one worktree, ask which. A lane whose agent is still `working` has a moving diff: say so and ask whether to review now or when it settles.

## 2. Start the reviewer

Use the `herdr:agent` skill.

- **Pane**: a new tab in the lane's workspace, working directory the lane's worktree, so both agents sit together.
- **Kind**: the one the user asked for; otherwise ask. A different kind from the lane's agent gives a more independent read.
- **Name**: `review-<lane or task id>`.
- **First prompt**, sent once:

```text
You are reviewing, not changing. Checkout: <worktree path>, branch <branch>, compared against <main branch>.
Use the peer-review skill on this branch's diff. It asks which provider should review and tells the user what is sent to that provider: ask that in this pane and wait; the orchestrator relays the user's answer.
Do not edit files, commit, push or touch the project board. Report the findings by severity, each with file and line, and say plainly when there are none.
```

## 3. Listen and report

Follow the reviewer with the `herdr:listen` skill. Its provider question and its disclosure about sending code to an external provider go to the user word for word; relay the answer with `herdr:prompt`. Sending code outside is the user's decision, never yours.

When it settles, report the findings as the reviewer gave them, labelled with their source. Do not apply them. If the user wants them fixed, pass them to the lane's own agent with `herdr:prompt` once it is idle.
