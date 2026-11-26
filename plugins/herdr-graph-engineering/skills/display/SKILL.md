---
name: display
description: Shows the graph engineering lanes - which need you, which are working, which are done - with each lane's node chain, retries, open question and file references, read from the lane files and Herdr. Read-only. Use for '/herdr-graph-engineering:display', 'show the graph', 'what needs me', 'how are the lanes doing'. Requires jq, yq and git.
allowed-tools: Bash
---

# Display the lanes

Paths are relative to this `SKILL.md`. This skill only reads; it never changes a lane.

```bash
bash "../../scripts/status.sh" --text            # every repository with a Herdr workspace open, plus this one
bash "../../scripts/status.sh" --text --repo <dir>   # only that repository
```

Print the output **unchanged inside one fenced code block** (` ```text `), then, in prose:

- for each lane under `NEEDS YOU`: the exact question and what the user can answer;
- nothing else unless the user asked for more.

To see one lane in full, `bash "../../scripts/lane.sh" show --lane <lane> --repo <dir>` prints its lane file (graph copy, results, retries, history).

## A line in Herdr's tab bar

For an always-visible summary (`🔴 1 why-sync-slow  🟡 2  🟢 1`), the user can add this once to their Herdr config (`~/.config/herdr/config.toml`), with the absolute path of this plugin's `scripts/status.sh`. Offer it; do not edit their config yourself:

```toml
[[ui.tab_bar_right]]
type = "command"
command = "bash <absolute path>/scripts/status.sh --line"
interval_seconds = 5
```
