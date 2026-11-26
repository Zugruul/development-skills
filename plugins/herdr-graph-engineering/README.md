# herdr-graph-engineering

Graph engineering on [Herdr](https://herdr.dev), kept thin. You talk to **one orchestrator chat**. Every idea you give it becomes a **lane**: its own Herdr worktree running a small graph of steps copied from a **pattern**. The orchestrator starts what is ready, checks what comes back, retries within limits, and comes to you only when a lane needs you.

```text
you ›  start task: add rate limiting to the public API
you ›  investigate why the nightly sync got slow

graph › /herdr-graph-engineering:display
NEEDS YOU (1)
  why-sync-slow  investigate  investigate ?
    ? Which environment, staging or production?
WORKING (1)
  task-rate-limit  solo  impl ✓ → tests ⟳ retry 1/3
```

## Install

```bash
claude plugin marketplace add Zugruul/development-skills
claude plugin install herdr-graph-engineering@development-skills   # installs herdr too
```

Needs the `herdr` plugin, the `herdr` binary (the agent runs inside a Herdr pane), and `bash` 3.2 or later (macOS default; WSL on Windows), `jq`, `yq` ([mikefarah/yq](https://github.com/mikefarah/yq) v4) and `git`. No Python.

## Skills

| Skill | Purpose |
|---|---|
| `orchestrate` | The one chat: route ideas into lanes, run each lane's graph, check evidence, retry within limits, relay questions, open a draft pull request when done |
| `display` | Read-only picture of every lane: `NEEDS YOU`, `WORKING`, `DONE` (the panel also lists `CLOSED`), each with its node chain, retries, open question and file references |

## Concepts

| | |
|---|---|
| **Lane** | One idea. One Herdr workspace (labelled with the lane name), one branch. |
| **Pattern** | A small YAML graph: `agent`, `gate`, `human` and `pr` (`pr: draft`: the orchestrator pushes the branch and opens or updates the draft pull request at that point) nodes; `needs`, `when` and `retry` (with a `max`) edges; `done` checks. Frozen: no other keys, no expressions. |
| **Role** | The brief an agent node gets: Markdown with frontmatter (`name`, `description`, `kind` preference list, `access`). |
| **Lane file** | `<git common dir>/herdr-graph/<lane>.yaml`: only what Herdr and git cannot show (idea, graph copy, approved gate command, node results, retries, open question, owner, history). Written only by `lane.sh`, under a lock. |

Patterns and roles are looked up in the repository's `.herdr-graph/patterns|roles/`, then `~/.config/herdr-graph/patterns|roles/`, then this plugin. To add a kind of work, add a pattern; to add an agent, add a role. No skill changes.

Shipped patterns:

| Pattern | Graph |
|---|---|
| `solo` | implementer → tests gate (retry up to 3) → draft pull request |
| `pair` | the same, then a read-only reviewer of another kind; `changes` sends the work back to the implementer (up to 2) |
| `fast` | urgent fixes, only when you ask (fast, urgent, hotfix, pull request ASAP): the smallest fix with a focused test → the draft pull request opens at once (`pr` node) → tests gate; a failure goes back to the implementer (up to 3) and the fix is pushed to the same pull request |
| `investigate` | a read-only investigator writes a report |
| `review` | a pull request reviewer drafts → you approve → a poster posts one grouped `COMMENT` review whose body is the summary, verified |
| review stack | `make-review-stack.sh` writes the graph for related pull requests: one reviewer each in parallel → a cross-PR check → you approve → one poster each |
| `plan` | a planner drafts a custom graph; you approve it before it runs |

```yaml
# patterns/solo.yaml
when: "Implement, fix or change something in one area of one repository."
inputs: [idea]
nodes:
  impl:  { agent: implementer, access: write, brief: "{idea}" }
  tests: { gate: "{gate}", needs: [impl], retry: { to: impl, max: 3, on: fail } }
done:
  - gate: tests
  - draft-pr
```

## Agent kinds

A role lists kinds in order of preference (`kind: [claude, codex, opencode]`). `kind.sh` picks the first installed one; for a second opinion it skips the implementer's kind. Read-only access is enforced by the agent CLI, then checked with `git status` after the node:

| Kind | Read-only |
|---|---|
| claude | `--disallowedTools Edit Write NotebookEdit` |
| opencode | `--agent plan` |
| codex | `--sandbox read-only` |

## Scripts

```text
lane.sh new|show|list|node|retry|ask|answer|set|close|clear|restore   the only writer of lane files
ready.sh --lane L                                       which nodes can start now
kind.sh --role R [--not KIND]                           the kind and arguments for a role here
gate.sh --lane L --node N --pane P                      run a gate in a visible tab, record its exit code
status.sh [--text|--line|--json]                        the picture of every lane (display, tab bar)
check-pattern.sh (FILE | --name P)                      validate a pattern
make-review-stack.sh --pr URL --pr URL ... --out FILE    the graph for reviewing related pull requests
check.sh                                                inside Herdr?
panel.sh / panel-action.sh / popup.sh                   the Herdr panel, its actions and popups
measure.sh [--json]                                     how the lanes went: outcome, minutes, retries, questions
```

## What the orchestrator may do alone

Start agents and gates, retry within a pattern's limit, commit, push the lane branch, open a **draft** pull request. It asks before marking a pull request ready, posting anywhere, or touching anything outside the lane. It never merges, approves, force-pushes or deletes a branch.

## The Herdr panel

The folder is also a Herdr plugin (`herdr-plugin.toml`): a graph panel next to the orchestrator, installed into Herdr separately:

```bash
herdr plugin install Zugruul/development-skills/plugins/herdr-graph-engineering   # or: herdr plugin link <this folder>
```

```text
 NEEDS YOU (1)
 ▾ review-pr-812  review ◂    [detail] [answer]  (selected: row background)
   ├ review ✓ → post ?
   ├ ? post 4 findings                        (red)
   └ ● #812 open · approved  https://github.com/o/r/pull/812

 WORKING (1)
 ▾ task-rate-limit  solo
   ├ impl ✓ → tests ⟳ 2/3
   ├ last: 3 failing                          (grey)
   ├ ● #820 draft            https://github.com/o/r/pull/820
   └ ● #818 merged           https://github.com/o/r/pull/818

 DONE (1)
 ▸ investigate-sync  investigate              [x]
   ├ investigate: .../reports/sync.md         (click: opens it)

 CLOSED (6)       [clear all reviews] [clear all]
 ▸ fix-login  fast                           [x]  (folded)
 ▸ spike-cache  investigate                  [x]
   … 4 more

 Since last look: investigate-sync → done
 ──────────────────────────────────────────────────────────
  updated 10:42:07 · every 5s               [◷ 5s] [↻]
```

- `/herdr-graph-engineering:display` opens or closes it. Without the Herdr plugin, `display` prints the same picture as text.
- Refresh: automatic, every 5s by default (`refresh=10s` in `$(herdr plugin config-dir herdr-graph-engineering.graph)/config` changes the start); `[◷ 5s]` cycles 5s, 10s, 15s, 30s, 1m, 5m; `[↻]` refreshes now. No title of its own (Herdr's pane border shows "Graph"), one column of padding each side; a thin divider and the grey footer sit on the pane's bottom rows, the footer saying when it last read and ending with the two buttons. The size is read from the terminal on every draw and a resize redraws at once.
- Layout: each lane starts with its fold chevron (▾ unfolded, ▸ folded); its chain, question, references, last line and pull requests hang under it on ├ and └, and long lines wrap inside that.
- Pull requests: each lane lists the pull requests of its branch, in every state, and every GitHub pull request it mentions (idea, question, references, history), so a review lane lists the pull request it reviews. Coloured by state: draft grey, open blue, approved green, changes requested amber, merged purple, closed red. Click one to open it in the browser. `scripts/prs.sh fetch` asks `gh` and caches the answer next to the lane files; the panel starts it in the background at most once a minute and draws from the cache, so a render never waits on the network. Without `gh` the list stays empty.
- Colour: plain ANSI 24-bit, the same in the panel and its popups: section headers bold red / amber / green / grey (CLOSED), `[confirm]` red (green for `[restore]`), lane names bold, patterns, references, `last:` lines and the footer grey, node marks coloured by state, the selected lane's first line on a subtle background. `NO_COLOR` turns it off (the selected lane is then marked `◂`).
- Click only: the panel acts on mouse clicks and nothing else; keystrokes in it are ignored (no key quits, scrolls, folds or presses anything). Herdr passes mouse reports to the panel because the panel asks for them, so it needs Herdr's `ui.mouse_capture`. Toggling the panel itself is a Herdr action (below), outside the pane.
- A click on a lane selects it; a click on its chevron also folds or unfolds it; a double click on any of its lines (two clicks within 400 ms of the panel finishing the first) jumps to its agent, the blocked one first. A click on a pull request opens it in the browser; a click on any row of a file reference opens the file: a URL or an `.html` file in the browser, any other file in your editor (`$VISUAL`, else `$EDITOR`, else `open` on macOS or `xdg-open` on Linux). A terminal editor (vim, nvim, nano, micro, helix, `emacs -nw`, ...) cannot run inside the panel, so it opens in a new Herdr tab in the panel's workspace, which closes when the editor exits; set `GRAPH_EDITOR_TERMINAL=yes` or `no` when the guess is wrong. A GUI editor just starts.
- Buttons on a lane's first line, right-aligned: `[detail]` (the selected lane: its detail popup), `[answer]` (a lane that asks something: the answer popup; the answer goes to the orchestrator chat, which relays it), `[restore]` (the selected closed lane), `[x]` (a DONE or CLOSED lane). When they do not all fit the pane, they drop from the left (none in a pane too narrow for one).
- "Since last look" lists the lanes that moved section since your last click.
- CLOSED: the closed lanes of every repository the panel shows, newest first, folded (unfold one to see its pull requests in their final state); five, then `… n more` (click it to show all). A DONE or CLOSED lane ends with `[x]`, the CLOSED header with `[clear all]`, and left of it `[clear all reviews]` while a closed review lane exists. A review lane is one whose recorded pattern is `review` or `review-stack`; with no pattern or a custom one (a review stack started from `--pattern-file`), one on a `look/pr-<n>` branch. When the two buttons do not fit the pane's width, only `[clear all]` shows. `[x]`, `[restore]`, `[clear all reviews]` and `[clear all]` ask first: the first click turns the button into `[confirm]`, a second click on it acts, a click anywhere else puts it back. `[x]` on a DONE lane asks the lane's orchestrator to clean it up, which confirms with you before it removes the worktree; the panel removes nothing itself. On a CLOSED lane, `[clear all reviews]` (closed review lanes only) and `[clear all]` (every closed lane), it runs `lane.sh clear`, which moves the lane file from `closed/` to `closed/cleared/` (kept, no longer shown). `[restore]` (on the selected closed lane; its `[confirm]` is green) runs `lane.sh restore`, which moves the lane file back to the open lanes with its last status (a done lane comes back DONE) and records it in the lane's history; it refuses when an open lane has that name. Restoring brings back the record only: no worktree, branch or agent is recreated. A closed lane's pull requests are fetched until they are merged or closed.
- Actions to bind in your Herdr config (`[[keys.command]] type = "plugin_action"`): `herdr-graph-engineering.graph.toggle`, `.refresh`, `.next-needs-me`.
- Ctrl-click a `.md` report path or a GitHub pull request URL to open it in a popup.
- After a Herdr restart it reopens next to the orchestrator and rewrites the sidebar tokens; a lane whose worktree you remove by hand is closed.
- It only reads, except `[x]`, `[clear all reviews]` and `[clear all]` on closed lanes, which go through `lane.sh clear`, and `[restore]`, which goes through `lane.sh restore`. Lane files are still written only by `lane.sh`, answers still go through the orchestrator, and it stores nothing: it finds its own pane by its terminal title.
- It never filters Herdr's sidebar (older versions did, with `f`, `n` and `F`); at start it clears a filter such a version may have left, through `nc -U` when `nc` is there. `.refresh` reaches open panels as the private sequence `ESC [ 99 ~`, which no key sends.

## Tests

```bash
bash plugins/herdr-graph-engineering/tests/run-tests.sh
```

Hermetic: throwaway repositories and a stub `herdr`; no live session.

## Next

## Measuring

Run it on 10 to 20 real ideas, then `measure.sh` (or ask the orchestrator "how did the lanes go"): per lane the outcome, minutes, retries, questions to you and failures, and totals per pattern. Judge by the end state: did the lanes finish, how often were you asked, did retries run out. Remove a part (a node, a pattern, a check) that does not earn its place.
