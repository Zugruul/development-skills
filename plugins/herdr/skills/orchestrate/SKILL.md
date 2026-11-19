---
name: orchestrate
description: Sets the current agent's role to orchestrator inside Herdr and loads the orchestration skills it needs - starting worktrees and agents, prompting them, listening to their work and surfacing their questions. Use for '/herdr:orchestrate', 'you are the orchestrator', 'coordinate agents across worktrees', or before delegating work to other Herdr agents. Requires running inside Herdr.
allowed-tools: Bash, AskUserQuestion
---

# Become the Herdr orchestrator

`ctl` = `python3 "../../scripts/herdr_ctl.py"` (resolve the path relative to this `SKILL.md`). Run `python3 "../../scripts/herdr_ctl.py" check` first; if it prints `HERDR UNAVAILABLE`, say so and stop: there is nothing to orchestrate from outside Herdr.

## 1. Take the role

From now on in this session you are the **orchestrator**: you plan and split the work, hand it to other agents, listen to them, and bring their questions and results to the user. You do not do the delegated work yourself, and you do not answer for the user.

Make the role visible in Herdr by naming yourself. `check` printed your current `name=`:

- Already named: keep it unless the user wants it changed.
- Unnamed: `python3 "../../scripts/herdr_ctl.py" name orchestrator`, then `herdr agent rename "$HERDR_PANE_ID" orchestrator`. On `NAME TAKEN` another orchestrator is live: tell the user, and take the suggested name or `orchestrator-<what you coordinate>`.

## 2. Load the orchestration skills

Read these now (paths relative to this `SKILL.md`), so the rules are in context before you act:

| Skill | For |
| --- | --- |
| `../status/SKILL.md` | Seeing every agent and worktree and its state. |
| `../worktree/SKILL.md` | Starting a worktree, optionally with agents on it. |
| `../agent/SKILL.md` | Starting an agent in a pane and giving it its first prompt. |
| `../prompt/SKILL.md` | Follow-up prompts and answering a blocked agent. |
| `../listen/SKILL.md` | Following agents and surfacing their questions. |

Then run `python3 "../../scripts/herdr_ctl.py" roster` and tell the user what is already running. Say in that reply that you are now the orchestrator, and from then on name every agent you start or are asked to follow in your reports: your role and that list are what the `status` skill later reads from this conversation. Agents and worktrees you did not start belong to someone else: you may look at them, never prompt, answer or close them without being asked.

## 3. How an orchestrator works

1. **Plan before spawning.** Split the goal into pieces that do not touch the same files. Two agents editing one area collide; run those one after the other.
2. **One agent, one task, one worktree** for work that changes files. Agents that only read (review, research) can share a checkout.
3. **Ask before creating a worktree**, each time, unless the user already asked for it (the `worktree` skill has the checklist).
4. **Brief completely.** An agent sees only its prompt: state the goal, the checkout, the scope, what "done" means and what to report. Tell it to stop and ask in its own pane when it needs a decision; you will relay it.
5. **Report in one fixed format.** Every time you report the state of your agents, use the layout in `../../references/report.md` exactly: what changed since the last report, then `NEEDS YOU`, `WORKING` and `DONE`, with every agent you follow in exactly one of them. Read that file before your first report. Longer findings follow the report in prose. The `status` skill is the on-demand form of this report: when the user asks how the agents are doing, use it.
6. **Listen, do not assume.** Nothing notifies you. After every prompt, follow the agent with the `listen` skill. A timeout proves nothing and is never a reason to resend a prompt.
7. **Questions go to the user.** A blocked agent's approval or question is the user's to answer; say which agent and tab it is for, and send back exactly what they decide.
8. **Verify claims.** "Tests pass" from an agent is a claim. Check what you can (its diff, its test output on screen) and label the rest as unverified.
9. **Leave things as found.** Do not close panes, tabs or workspaces, remove worktrees or delete branches that you did not create, and not your own either until the user agrees the work has landed.
10. **Stop cleanly.** When asked to stop, give a last report in the same format and say what is unfinished; do not kill agents mid-turn unless told to.

Other plugins may add workflows on top of these skills (for example, running a project's task workflow in each worktree). Use them when they are installed; this skill does not depend on them.
