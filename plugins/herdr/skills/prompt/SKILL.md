---
name: prompt
description: Sends a follow-up prompt to a Herdr agent, or answers the approval or question it is blocked on, without ever submitting the same text twice. Use for '/herdr:prompt', 'tell the dev agent to also update the docs', 'answer yes to the reviewer agent', or when the listen skill surfaced a blocked agent and the user has decided the answer. Requires running inside Herdr.
allowed-tools: Bash, AskUserQuestion
---

# Prompt or answer a Herdr agent

Run `bash "../../scripts/check.sh"` first (paths are relative to this `SKILL.md`). If it prints `HERDR UNAVAILABLE`, say so and stop.

Target an agent by its unique name, or by the pane id it runs in. If the request does not say which agent and more than one could be meant, list the live agents (`herdr agent list`) and ask.

## Send a prompt

Look at the agent first: `herdr agent get <target>` and read `.result.agent.agent_status`.

- `blocked`: it waits at a dialog. Do not prompt; go to "Answer a blocked agent".
- `working`: it is mid-turn. Wait for it (the `listen` skill), unless the user wants to steer it now.
- `idle`, `done`: send.

```bash
herdr agent prompt <target> "<prompt>" --wait --timeout 600000
```

Herdr submits the text once, then waits until the agent shows activity and settles. Long text: put it in a file and pass `"$(cat <file>)"`.

| Answer | Meaning | Do |
| --- | --- | --- |
| success, `.result.agent.agent_status` | The agent took the prompt and settled. | Read its screen (the `listen` skill). |
| `agent_blocked` | It was blocked; **nothing was sent**. | Go to "Answer a blocked agent". |
| `agent_prompt_stalled` | Sent, but no activity within 5 seconds. | Read the screen before anything else. |
| `timeout` | Sent; the agent is still working. | Keep listening. |

**After `agent_prompt_stalled`, a timeout or any other error: never resend the same prompt blindly.** A missing confirmation does not prove the prompt was not delivered, and a second copy makes the agent do the work twice. Read the screen first (`herdr agent read <target> --source visible --lines 80`): if the text sits unsent in the input box, submit it with `herdr agent send-keys <target> enter`; if the agent is working on it, it arrived; only when the screen shows no trace of it, send it again.

## Answer a blocked agent

A blocked agent shows an approval or a question. That decision belongs to a human.

1. Read it: `herdr agent read <target> --source visible --lines 80`.
2. **Ask the user** what to answer, quoting the agent's question and its options exactly, and naming the agent, its tab and what it was doing. Do not approve, deny or pick an option on your own, even when one looks obviously right. The one exception: the user already gave, in this conversation, a standing answer for exactly this kind of question, or a delegation that covers deciding it.
3. Send the answer the way the dialog expects it:
   - an options dialog: `herdr agent send-keys <target> <key> [key ...]` (for example `1`, `y`, `down enter`, `esc`);
   - a free-text question: `herdr agent send-keys` cannot type sentences, so once the dialog accepts text, use `herdr agent prompt <target> "<answer>"`.
4. Read the screen again: confirm the dialog is gone and report what the agent did next.

Never send keys to a pane to "see what happens". Never answer for an agent you cannot identify.
