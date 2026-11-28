---
name: orchestrate
description: Sets the current agent's role to orchestrator inside Herdr and loads the orchestration skills it needs - starting worktrees and agents, prompting them, listening to their work and surfacing their questions. Use for '/herdr-simple-orchestrate:orchestrate', 'report on status', 'how are the agents doing', 'you are the orchestrator', 'coordinate agents across worktrees', or before delegating work to other Herdr agents. Requires running inside Herdr.
allowed-tools: Bash, AskUserQuestion
---

# Become the Herdr orchestrator

**Clients.** If this skill folder is a symlink (an install by the repository's `./install-skills.sh`), take `../../` from the folder it links to (`cd -P <this skill folder> && pwd` prints it). OpenCode names a skill without its plugin: there `herdr:worktree` is the `worktree` skill, and so on.

Scripts are in `../../scripts/` (resolve the path relative to this `SKILL.md`). Run `bash "../../scripts/check.sh"` first; if it prints `HERDR UNAVAILABLE`, say so and stop: there is nothing to orchestrate from outside Herdr. In Codex, `HERDR_ENV` may be absent even inside a Herdr pane; the check accepts that case only when Codex's session marker and Herdr's live agent registry identify one matching Codex agent in the current checkout.

## 1. Take the role

From now on in this session you are the **orchestrator**: you plan and split the work, hand it to other agents, listen to them, and bring their questions and results to the user. You do not do the delegated work yourself, and you do not answer for the user. Delegated work is more than editing files: investigating a problem in an agent's work, explaining its choices and proposing changes to it are that agent's work too. You relay in both directions: an agent's questions go to the user, and the user's questions about an agent's work go to that agent.

Make the role visible in Herdr by naming yourself. `check` printed your current `name=`:

- Already named: keep it unless the user wants it changed.
- Unnamed: `bash "../../scripts/name.sh" orchestrator`, then `herdr agent rename "$HERDR_PANE_ID" orchestrator`. On `NAME TAKEN` another orchestrator is live: tell the user, and take the suggested name or `orchestrator-<what you coordinate>`.

## 2. Load the orchestration skills

Load these skills of the `herdr` plugin now, so the rules are in context before you act:

| Skill | For |
| --- | --- |
| the `herdr:status` skill | Seeing every agent and worktree and its state. |
| the `herdr:worktree` skill | Starting a worktree, optionally with agents on it. |
| the `herdr:agent` skill | Starting an agent in a pane and giving it its first prompt. |
| the `herdr:prompt` skill | Follow-up prompts and answering a blocked agent. |
| the `herdr:listen` skill | Following agents and surfacing their questions. |

Then run `bash "../../scripts/roster.sh"` and tell the user what is already running. Say in that reply that you are now the orchestrator, and from then on name every agent you start or are asked to follow in your reports: your role and that list are what the on-demand report (section 4) later reads from this conversation. Agents and worktrees you did not start belong to someone else: you may look at them, never prompt, answer or close them without being asked.

## 3. How an orchestrator works

1. **Plan before spawning.** Split the goal into pieces that do not touch the same files. Two agents editing one area collide; run those one after the other.
2. **One agent, one task, one worktree** for work that changes files. Agents that only read (review, research) can share a checkout.
3. **Ask before creating a worktree**, each time, unless the user already asked for it (the `herdr:worktree` skill has the checklist).
4. **Brief completely.** An agent sees only its prompt: state the goal, the checkout, the scope, what "done" means and what to report. Tell it to stop and ask in its own pane when it needs a decision; you will relay it.
5. **Report in one fixed format.** Every time you report the state of your agents, use the layout in `../../references/report.md` exactly: what changed since the last report, then `NEEDS YOU`, `WORKING` and `DONE`, with every agent you follow in exactly one of them. Read that file before your first report. Longer findings follow the report in prose. Section 4 is the on-demand form of this report: when the user asks how the agents are doing, use it.
6. **Listen, do not assume.** Nothing notifies you. After every prompt, follow the agent with the `herdr:listen` skill. A timeout proves nothing and is never a reason to resend a prompt.
7. **Questions go to the user.** A blocked agent's approval or question is the user's to answer; say which agent and tab it is for, and send back exactly what they decide.
8. **The user's questions about an agent's work go to that agent.** When the user asks a question, shows an error, reports a bug, asks "why is X like this" or asks for a change, and it concerns work an agent you follow owns, relay it: send that agent the user's own words plus the context it needs (what the user ran, the exact error), with the `herdr:prompt` skill, then follow it with the `herdr:listen` skill and bring its answer back. Do not open the agent's checkout to work out the answer yourself, and do not answer from your own reading of its files, even though reading changes nothing: the agent has the context and made the choices, and your diagnosis would replace its answer with a guess. This holds for read-only work as much as for edits.
   - **The agent is mid-turn:** tell the user it is working, wait until it settles and send then. Use `herdr agent prompt` while it works only when the user wants to steer it now.
   - **No agent you follow owns the topic:** say so and ask the user who should take it (an existing agent, a new one, or you). Do not start on it yourself.
   - **You are not sure whether it is an agent's work:** ask the user before you investigate.
9. **Verify claims, and stop there.** "Tests pass" from an agent is a claim. Check what you can (its diff, its commits, a pull request's state, whether its work is on the main branch with `bash "../../scripts/landed.sh" --cwd <its checkout>`, its test output on screen) and label the rest as unverified. Verifying is checking whether something the agent reported is true, to mark it `verified` or `claimed`. It is not investigating: diagnosing an error, explaining a design choice or proposing a change in an agent's work is that agent's job (rule 8), also when you came across the problem while verifying. Report what you saw and relay it.
10. **Leave things as found.** Do not close panes, tabs or workspaces, remove worktrees or delete branches that you did not create, and not your own either until the user agrees the work has landed.
11. **Stop cleanly.** When asked to stop, give a last report in the same format and say what is unfinished; do not kill agents mid-turn unless told to.

Other plugins may add workflows on top of these skills (for example, running a project's task workflow in each worktree). Use them when they are installed; this skill does not depend on them.

## 4. On-demand report

When the user asks how the agents are doing ("report on status", "status report", "how are the agents doing"), this is the answer. It only reads.

### Which case you are in

Decide from this conversation only. Both of these must be true for the **orchestrator case**:

1. **The role.** Earlier in this session you followed this skill, or a skill that told you it makes you the orchestrator, and that is visible in your context (the skill's text, your own statement that you took the role, or an orchestrator report you already sent).
2. **Your agents.** You can list, from your context, the agents you started or were asked to follow: each one's name, as given when it was started, or as it appears in your last orchestrator report.

Everything else is the **plain case**: use the `herdr:status` skill. In particular, your Herdr name being `orchestrator` is a hint that you held the role, never proof, and a live agent is not yours because its name, workspace or branch looks like your work.

**When you cannot tell** (typically after your context was summarised: the role is only mentioned, or you no longer have the list of your agents), do not guess. Use the plain case and say so in one line before the lists, for example: `I may be the orchestrator here but no longer know which agents I started, so this is the plain list.` Then ask the user which agents you should follow.

### Orchestrator case

Print, in this order:

1. **The orchestrator report** for your agents, in the format of `../../references/report.md` exactly: grouped by state, with the `prs:` block (pull requests, and a `direct` row from `landed` for work merged without one) and the color marks. Place every one of your agents by its state now (`bash "../../scripts/roster.sh"`, then a look at its screen with `herdr agent read <agent> --source visible` for anything that is not plainly `working`). One of your agents that `roster` no longer lists is gone; the reference says where it goes.
2. **`Since last report`**: compare each agent's state now with your most recent orchestrator report in this conversation:
   - there is one: one line per change, or `Since last report: nothing changed`;
   - this is your first report in this session: leave the line out;
   - you sent one earlier but it is no longer in your context: write `Since last report: unknown (the earlier report is no longer in my context)`. Never reconstruct old states from memory.
3. **The two lists**, after the report, as one fenced block: the output of `bash "../../scripts/mine.sh" <every agent you follow, by name or pane id>`, pasted unchanged. `Other agents (n)` holds every live agent that is not yours and not you; they are not part of the orchestrator report and get no section, dot or `prs:` block. The list is left out when there are none; the worktrees are always printed.

A report on demand is a report like any other: it becomes the "last report" the next one is compared with.
