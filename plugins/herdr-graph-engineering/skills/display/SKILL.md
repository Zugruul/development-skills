---
name: display
description: Shows the graph engineering lanes - which need you, which are working, which are done - with each lane's node chain, retries, open question and file references, read from the lane files and Herdr. Read-only. Use for '/herdr-graph-engineering:display', 'show the graph', 'what needs me', 'how are the lanes doing'. Requires jq, yq and git.
allowed-tools: Bash
---

# Display the lanes

Paths are relative to this `SKILL.md`. This skill only reads; it never changes a lane.

## With the Herdr panel (preferred)

If the graph panel plugin is installed in Herdr (`herdr plugin list --json | jq -r '.result.plugins[].plugin_id'` lists `herdr-graph-engineering.graph`, enabled), `/display` **opens or closes** it next to the orchestrator:

```bash
herdr plugin action invoke herdr-graph-engineering.graph.toggle
```

Say in one line that it is open (or closed). The panel refreshes itself: every 5 seconds by default (`[◷ 5s]` or `t` cycles 5s, 10s, 15s, 30s, 1m, 5m), `[↻]` or `r` refreshes at once, and its footer, at the bottom with the two buttons, shows when it last read. Below DONE, a CLOSED section lists the closed lanes of every repository, newest first, five before `… n more`. Each lane lists its pull requests (its branch's and those it mentions), coloured by state; a click opens one in the browser. In the panel: ↑↓ select a lane, enter, space or a click on its chevron folds or unfolds it, `g` jumps to its agent, `a` answers its question (the answer comes to the orchestrator chat), `d` shows its detail, `x` (pressed twice, or a click on `[x]` then `[confirm]`) asks the orchestrator to clean up a DONE lane or clears a CLOSED one from the list, `X` clears every closed lane, `f` shows only that lane's agents in the sidebar, `n` only the agents that need you, `F` all again, `q` closes it.

Not installed: say once that it can be installed with `herdr plugin install Zugruul/development-skills/plugins/herdr-graph-engineering` (it asks before installing), then show the text below.

## As text

```bash
bash "../../scripts/drift.sh" --quiet            # first: read finished agents' RESULT lines (writes only its cache, never a lane file)
bash "../../scripts/status.sh" --text            # every repository with a Herdr workspace open, plus this one
bash "../../scripts/status.sh" --text --repo <dir>   # only that repository
```

Print the output **unchanged inside one fenced code block** (` ```text `), then, in prose:

- for each lane under `NEEDS YOU`: the exact question (`?`) or what needs the user (`!`: an agent that finished, is blocked or gone, a merged pull request) and what the user can answer;
- nothing else unless the user asked for more.

To see one lane in full, `bash "../../scripts/lane.sh" show --lane <lane> --repo <dir>` prints its lane file (graph copy, results, retries, history).

## Optional: Herdr's tab bar and sidebar

Offer these once; never edit the user's Herdr config yourself. In `~/.config/herdr/config.toml`, with the absolute path of this plugin's `scripts/status.sh`:

```toml
[[ui.tab_bar_right]]            # always-visible summary: 🔴 1 why-sync-slow  🟡 2  🟢 1
type = "command"
command = "bash <absolute path>/scripts/status.sh --line"
interval_seconds = 5

[ui.sidebar.agents]             # each lane agent's row shows its lane, node and step
rows = [["state_icon", "workspace", "tab"], ["agent", "$node", "$step"]]
```

The sidebar tokens are written by the orchestrator (`status.sh --tokens`) and rewritten by the panel plugin after a Herdr restart.
