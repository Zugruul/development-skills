---
name: listen
description: Listens to one or more Herdr agents and reports what each is doing; when an agent is blocked on a question or approval it shows that question and asks the user how to answer, asking which agent or tab is meant when that is unclear. Use for '/herdr:listen', 'watch the dev agent', 'what is the agent in that worktree doing', 'tell me when they finish or need me'. Requires running inside Herdr.
allowed-tools: Bash, AskUserQuestion
---

# Listen to Herdr agents

Run `bash "../../scripts/check.sh"` first (paths are relative to this `SKILL.md`). If it prints `HERDR UNAVAILABLE`, say so and stop.

Nothing notifies you when another agent finishes or blocks. Listening means waiting on Herdr's state yourself.

## 1. Which agents

Treat the rest of the request as the agents to listen to: names, pane ids, or a worktree or workspace (then: every agent in it).

```bash
herdr agent list | jq -r '.result.agents[] | [.workspace_id, .pane_id, .tab_id, (.name // "-"), .agent, .agent_status, .cwd] | @tsv'
```

- A worktree or workspace with several agents, and the user named none: listen to all of them, and say so.
- A request that could mean several agents (`the reviewer` with two reviewers live, an unnamed agent, a bare tab number): ask which agent or tab, listing each candidate's name, pane, tab, workspace and state. Do not guess.
- Unnamed agents are targeted by pane id.
- Never listen to yourself (your pane is `$HERDR_PANE_ID`).

## 2. Report what each is doing now

```bash
herdr agent get <target>                                    # .result.agent.agent_status
herdr agent read <target> --source visible --lines 80       # the screen
```

Agents with a full-screen interface keep their transcript on the visible screen, and `--source recent-unwrapped` misses it; `--source visible` shows it. Use `--source recent-unwrapped --lines 200` only for agents that scroll plain output.

Summarise per agent in a line or two: the state (`working`, `idle`, `done`, `blocked`, `unknown`) and what it is on, from the screen. Report what you read, not what you expect. `idle` and `done` usually mean ready for input, not that the task succeeded: read the last output before calling work finished. `unknown` means Herdr cannot tell; it is not completion.

## 3. Wait for something worth reporting

One agent:

```bash
herdr agent wait <target> --until blocked --until done --until idle --timeout 540000
```

Several agents at once:

```bash
bash "../../scripts/listen.sh" <target> [<target> ...] [--timeout 540] [--only-blocked]
```

It returns at the first agent that is blocked, settled (`idle`/`done`) or gone, printing one `EVENT` line each plus the screen of every blocked agent, and `STILL WORKING` for the rest. Run either in the background when your host can do that, so the user can still talk to you; otherwise keep the timeout under your host's command limit and call it again.

- A timeout means only that nothing changed. A timeout does not prove an earlier prompt was not delivered. Keep listening or read the screen; never resend a prompt because of a timeout.
- After an event, listen again to the agents that are still working, leaving out the ones already reported, until the user's goal is met or they tell you to stop.

## 4. When an agent is blocked

Surface it at once; a blocked agent does nothing until someone answers.

1. Tell the user which agent (name, workspace, tab, pane), what it was doing, and its question with the options exactly as shown on its screen.
2. Ask the user how to answer. Several agents blocked at once: one question per agent, each labelled with its agent and tab, never a merged "approve all?".
3. If the user's answer does not say which agent it is for and more than one is blocked, ask which agent or tab before sending anything.
4. Send the answer with the `prompt` skill (`../prompt/SKILL.md`), then go back to listening.

Do not answer an approval or a question yourself, unless the user already gave a standing answer or a delegation that covers it. If you can show a notification so the user notices, do: `herdr notification show "<agent> needs you" --body "<the question, short>" --sound request`.

## 5. When an agent settles or disappears

- `idle` / `done`: read its screen, report the outcome in its own words (what it changed, what it says is left, any error), and say whether the result is verified or only claimed.
- `gone`: the agent exited or its pane closed. Say so; do not restart it without being asked.
