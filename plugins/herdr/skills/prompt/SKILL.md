---
name: prompt
description: Sends a follow-up prompt to a Herdr agent, or answers the approval or question it is blocked on, without ever submitting the same text twice. Use for '/herdr:prompt', 'tell the dev agent to also update the docs', 'answer yes to the reviewer agent', or when the listen skill surfaced a blocked agent and the user has decided the answer. Requires running inside Herdr.
allowed-tools: Bash, AskUserQuestion
---

# Prompt or answer a Herdr agent

`ctl` = `python3 "../../scripts/herdr_ctl.py"` (resolve the path relative to this `SKILL.md`). Run `python3 "../../scripts/herdr_ctl.py" check` first; if it prints `HERDR UNAVAILABLE`, say so and stop.

Target an agent by its unique name, or by the pane id it runs in. If the request does not say which agent and more than one could be meant, show `python3 "../../scripts/herdr_ctl.py" roster` and ask.

## Send a prompt

```bash
python3 "../../scripts/herdr_ctl.py" prompt <target> --text "<prompt>"      # or --file <path> for long text
```

| Output | Meaning | Do |
| --- | --- | --- |
| `PROMPT DELIVERED` | The agent started working on it. | Follow it with the `listen` skill. |
| `PROMPT REFUSED` ... blocked | It waits at a dialog; nothing was sent. | Go to "Answer a blocked agent". |
| `PROMPT REFUSED` ... working | It is mid-turn; nothing was sent. | Wait for it, or add `--while-working` if the user wants to steer it now. |
| `PROMPT UNCONFIRMED` (exit 5) | The text was submitted; no activity was seen. | `python3 "../../scripts/herdr_ctl.py" peek <target>` and read the screen. |

**After `PROMPT UNCONFIRMED`, a timeout or any error: never resend the same prompt blindly.** A missing confirmation does not prove the prompt was not delivered, and a second copy makes the agent do the work twice. Read the screen first: if the text sits unsent in the input box, submit it with `herdr agent send-keys <target> enter`; if the agent is working on it, it arrived; only when the screen shows no trace of it, send it again.

## Answer a blocked agent

A blocked agent shows an approval or a question. That decision belongs to a human.

1. Read it: `python3 "../../scripts/herdr_ctl.py" peek <target>`.
2. **Ask the user** what to answer, quoting the agent's question and its options exactly, and naming the agent, its tab and what it was doing. Do not approve, deny or pick an option on your own, even when one looks obviously right. The one exception: the user already gave a standing answer for exactly this kind of question in this conversation.
3. Send the answer the way the dialog expects it:
   - an options dialog: `herdr agent send-keys <target> <key> [key ...]` (for example `1`, `y`, `down enter`, `esc`);
   - a free-text question: `herdr agent send-keys` cannot type sentences, so once the dialog accepts text, use `python3 "../../scripts/herdr_ctl.py" prompt <target> --text "<answer>"`.
4. Look again with `peek`: confirm the dialog is gone and report what the agent did next.

Never send keys to a pane to "see what happens". Never answer for an agent you cannot identify.
