---
name: ui-mode
description: Checks, enables, or disables Iterative UI mode (delegating UI decisions to the human via the decision hub). Use with 'status' (default), 'on', or 'off' — when the user asks whether the mode is active, wants UI questions to stop (going AFK), or wants them back.
---

# Iterative UI mode — status / on / off

One command does everything; run it with the action the user asked for (`status` if unspecified):

```bash
bash "../../scripts/ui-mode.sh" status   # ON, or OFF with the reason
bash "../../scripts/ui-mode.sh" off      # this clone stops delegating UI decisions
bash "../../scripts/ui-mode.sh" on       # delegate again
```

Report the script's output verbatim — it names the mechanism (`.claude/ITERATIVE_UI_OFF` local flag, or the project-wide `methodology.iterativeUI=false` in `.claude/project.yaml`). The flag is local and gitignored: toggling never affects other clones or CI.

After turning **off**: check for decisions still pending in the hub (`python3 "../../scripts/ui-hub.py" status`); if any, tell the user those cards will now be decided by the agent unless they answer them first.
After turning **on**: remind the user of the hub URL if the server is running.
If `on` still reports OFF, the project config is the kill switch — changing that is a repo change (edit `methodology.iterativeUI`), so confirm before touching it.

**This skill only toggles the mode — it never itself presents UI options.** If the human's request (in the same message, or shortly before/after invoking this skill) is to see, compare, or choose between UI design alternatives, and status comes back ON, that's the `ui-options` skill's job: invoke it next, before doing any other UI-mockup work. Do NOT reach for the `Artifact` tool for this — publish-to-artifact breaks the answer channel back to this session (the hub is what routes the human's pick back to the agent), so a UI-comparison page built as an Artifact is a dead end even if it looks fine to the human. This applies even when the human's message only says something like "/ui-mode" or "let's use ui-mode for this" without naming `ui-options` explicitly — mentioning ui-mode in the context of a design/layout decision IS the cue to route through `ui-options`, not just to report the toggle status.
