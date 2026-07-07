---
name: ui-mode
description: Checks, enables, or disables Iterative UI mode (delegating UI decisions to the human via the decision hub). Use with 'status' (default), 'on', or 'off' — when the user asks whether the mode is active, wants UI questions to stop (going AFK), or wants them back.
---

# Iterative UI mode — status / on / off

One command does everything; run it with the action the user asked for (`status` if unspecified):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ui-mode.sh" status   # ON, or OFF with the reason
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ui-mode.sh" off      # this clone stops delegating UI decisions
bash "${CLAUDE_PLUGIN_ROOT}/scripts/ui-mode.sh" on       # delegate again
```

Report the script's output verbatim — it names the mechanism (`.claude/ITERATIVE_UI_OFF` local flag, or the project-wide `methodology.iterativeUI=false` in `.claude/project.yaml`). The flag is local and gitignored: toggling never affects other clones or CI.

After turning **off**: check for decisions still pending in the hub (`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/ui-hub.py" status`); if any, tell the user those cards will now be decided by the agent unless they answer them first.
After turning **on**: remind the user of the hub URL if the server is running.
If `on` still reports OFF, the project config is the kill switch — changing that is a repo change (edit `methodology.iterativeUI`), so confirm before touching it.
