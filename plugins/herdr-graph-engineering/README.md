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

A role lists kinds in order of preference (`kind: [claude, codex, opencode]`). The orchestrator never picks a kind silently: before each agent node it runs `kind.sh --role R --list` and asks you, offering every kind that is actually installed (the kinds `herdr agent start --help` supports whose executable is on PATH), the recommended one first with why. For a reviewing role the recommendation is a different kind from the implementer's (`--not`); the implementer's kind is still offered, marked same-model. You can make a choice **standing** for the session ("use opencode for reviews from now on"): `kind.sh --remember` records it and later lanes use it without asking, unless that kind is gone. When an agent fails to start or work (an expired provider login, a dialog it cannot pass), you are offered every other installed kind (`--without` the failed one).

Read roles (`investigator`, `reviewer`, `pr-reviewer`, `planner`) run in each kind's normal mode. The CLI read-only modes stop what these roles must do: write the report or draft to a file outside the checkout, and run the tests.

| Kind | CLI read-only mode | Why it is not used |
|---|---|---|
| claude | `--disallowedTools Edit Write NotebookEdit` | blocks the Write tool, so the report could only be written through the shell. A path-scoped deny (`Edit(./**)`) needs shell quoting that the start path does not guarantee. |
| opencode | `--agent plan` | the plan agent cannot write the draft file or run tests (a pr-reviewer ended with `RESULT: question` and no draft) |
| codex | `--sandbox read-only` | cannot write the report or the temporary files tests create |
| any other | none known | |

The guard is the role's read-only rules in its brief and the orchestrator's check that the checkout is unchanged (`HEAD` and `git status --porcelain`, noted before the node and compared after); any change fails the node. `kind.sh` prints `GUARD brief` for a read role to say so.

### Startup dialogs

A new agent often stops before its brief: folder trust, imports of instruction files from outside the checkout, opencode asking to read `~/.claude` or `~`, a login. The orchestrator relays each one exactly, with lane and node, answers only as you say, and offers a **standing answer** for the session ("allow external CLAUDE.md imports for lanes in this repository") so the same dialog in later lanes does not come back to you.

## Scripts

```text
lane.sh new|show|list|node|retry|ask|answer|note|done-extra|set|close|clear   the only writer of lane files
session.sh set|add|del|show|find                       the only writer of the orchestrator's session file
resume.sh [--fetch] [--out FILE]                        everything the orchestrator needs after a compaction, one block
ready.sh --lane L                                       which nodes can start now
kind.sh --role R [--not K] [--without K] --list|--kind K|--remember K   the installed kinds (recommended first), the chosen one's arguments, standing choices
gate.sh --lane L --node N --pane P                      run a gate in a visible tab, record its exit code
close-done.sh --lane L [--dry-run]                      close the tabs of finished agent and gate nodes (CLOSE/KEEP per node)
cleanup.sh check | run --lane L                          find lanes ready for cleanup and ask; clean one up after your yes
status.sh [--text|--line|--json]                        the picture of every lane (display, tab bar)
check-pattern.sh (FILE | --name P)                      validate a pattern
make-review-stack.sh --pr URL --pr URL ... --out FILE    the graph for reviewing related pull requests
check.sh                                                inside Herdr?
panel.sh / panel-action.sh / popup.sh                   the Herdr panel, its actions and popups
install-keys.sh [--write]                               the Herdr shortcut for the panel: PREFIX then Alt+G
measure.sh [--json]                                     how the lanes went: outcome, minutes, retries, questions
```

## When a node's tab closes

Every agent and gate node runs in its own tab, recorded in the lane file (`lane.sh node --tab`). After each node record and at lane done the orchestrator runs `close-done.sh`, which decides from the lane's graph:

- an agent tab closes once its node is `done` and passed, no `retry` edge that has not passed can still send work back to it (an implementer stays until its gate and reviewer pass), and no `human` node after it is still undecided (a reviewer stays until `approve`, so it can be asked about its draft);
- a gate tab closes once its result is recorded as passed; a failed gate stays visible until the retry runs;
- at lane done or close, every agent and gate tab of the lane closes.

Never closed: a tab not recorded for a node, a running or blocked node, an agent Herdr shows working or blocked, the first tab of the lane's workspace, a tab outside it. The worktree stays until you agree to cleanup.

## Cleanup after a lane

The orchestrator does not wait for you to notice a merge. Before every report and after a lane is done it runs `cleanup.sh check`. A done lane is ready for cleanup when its pull request is merged (the recorded one, else the one for its branch), its checkout is clean and nothing in it is unpushed; a review lane (branch `look/pr-<n>`) is ready once it is done, and a report lane once nothing is unpushed. A ready lane goes under NEEDS YOU with a cleanup question and a Herdr notification, and `status.sh --text` (and the panel) shows `cleanup: ready`. Nothing is removed until you say yes and the orchestrator records it (`cleanup: confirmed`; `cleanup.sh run` refuses without it); then `cleanup.sh run` closes the lane's tabs, removes the worktree with `herdr worktree remove` (never `--force`) and closes the lane. The branch is kept. A merged lane with a dirty checkout or unpushed commits is never removed: it goes under NEEDS YOU with the reason. A no is remembered (`cleanup: declined`).

## What the orchestrator may do alone

Start agents and gates, retry within a pattern's limit, commit, push the lane branch, open a **draft** pull request. It asks before marking a pull request ready, posting anywhere, or touching anything outside the lane. It never merges, approves, force-pushes or deletes a branch.

## The Herdr panel

The folder is also a Herdr plugin (`herdr-plugin.toml`): a graph panel next to the orchestrator, installed into Herdr separately:

```bash
herdr plugin install Zugruul/development-skills/plugins/herdr-graph-engineering   # or: herdr plugin link <this folder>
```

Shortcut: PREFIX then Alt+G opens or closes the panel. Herdr plugins cannot declare keys, so the binding goes in your Herdr `config.toml` (`$HERDR_CONFIG_PATH`, else `~/.config/herdr/config.toml`):

```bash
bash scripts/install-keys.sh           # prints the binding and where it goes; changes nothing
bash scripts/install-keys.sh --write   # appends it (backup first), checks it with herdr config check, rolls back if the check fails
herdr server reload-config             # load it without restarting
```

It binds `prefix+alt+g` to the `plugin_action` `herdr-graph-engineering.graph.toggle`. Running it again changes nothing when the toggle is already bound (to any key); it refuses when `prefix+alt+g` is taken by something else. Alt chords depend on your terminal (it must send Alt as Meta). The panel itself takes no keys: it is click only.

```text
 NEEDS YOU (1)
 ▾ review-pr-812  review ◂                    (selected: row background)
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

 CLOSED (6)                           [clear all]
 ▸ fix-login  fast                           [x]  (folded)
 ▸ spike-cache  investigate                  [x]
   … 4 more

 Since last look: investigate-sync → done
 ──────────────────────────────────────────────────────────
 updated 10:42:07 · every 5s · ↵ fold · g go · a answer
 d detail · x close · ? keys                 [◷ 5s] [↻]
```

- `/herdr-graph-engineering:display` opens or closes it. Without the Herdr plugin, `display` prints the same picture as text.
- Refresh: automatic, every 5s by default (`refresh=10s` in `$(herdr plugin config-dir herdr-graph-engineering.graph)/config` changes the start); `[◷ 5s]` or `t` cycles 5s, 10s, 15s, 30s, 1m, 5m; `[↻]` or `r` refreshes now. No title of its own (Herdr's pane border shows "Graph"), one column of padding each side; a thin divider and the grey footer sit on the pane's bottom rows, the footer saying when it last read and ending with the two buttons. The size is read from the terminal on every draw and a resize redraws at once.
- Layout: each lane starts with its fold chevron (▾ unfolded, ▸ folded); its chain, question, references, last line and pull requests hang under it on ├ and └, and long lines wrap inside that.
- Pull requests: each lane lists the pull requests of its branch, in every state, and every GitHub pull request it mentions (idea, question, references, history), so a review lane lists the pull request it reviews. Coloured by state: draft grey, open blue, approved green, changes requested amber, merged purple, closed red. Click one to open it in the browser. `scripts/prs.sh fetch` asks `gh` and caches the answer next to the lane files; the panel starts it in the background at most once a minute and draws from the cache, so a render never waits on the network. Without `gh` the list stays empty.
- Colour: plain ANSI 24-bit, the same in the panel and its popups: section headers bold red / amber / green / grey (CLOSED), `[confirm]` red, lane names bold, patterns, references, `last:` lines and the footer grey, node marks coloured by state, the selected lane's first line on a subtle background. `NO_COLOR` turns it off (the selected lane is then marked `◂`).
- Mouse: a click on a lane selects it; a click on its chevron also folds or unfolds it; a click on a pull request opens it; a click on a button presses it. Herdr passes mouse reports to the panel because the panel asks for them.
- "Since last look" lists the lanes that moved section since your last key or click.
- CLOSED: the closed lanes of every repository the panel shows, newest first, folded (unfold one to see its pull requests in their final state); five, then `… n more` (click it to show all). A DONE or CLOSED lane ends with `[x]`, the CLOSED header with `[clear all]`. The first click turns the button into `[confirm]`, a second click on it acts, a click anywhere else puts it back (keys: `x` on the selected lane, `X` for clear all, pressed twice). `[x]` on a DONE lane asks the lane's orchestrator to clean it up, which confirms with you before it removes the worktree; the panel removes nothing itself. On a CLOSED lane, and `[clear all]`, it runs `lane.sh clear`, which moves the lane file from `closed/` to `closed/cleared/` (kept, no longer shown). A closed lane's pull requests are fetched until they are merged or closed.
- Keys: ↑↓ select a lane; enter or space folds or unfolds it; `g` jumps to its agent (the blocked one first); `a` answers its question in a popup (the answer goes to the orchestrator chat, which relays it); `d` lane detail; `x` close or clear it, `X` clear every closed lane; `f` only this lane's agents in Herdr's sidebar, `n` only the agents that need you, `F` all again; `q` closes it.
- Actions to bind in your Herdr config (`[[keys.command]] type = "plugin_action"`): `herdr-graph-engineering.graph.toggle` (`install-keys.sh` binds it to PREFIX then Alt+G), `.refresh`, `.next-needs-me`.
- Toggle finds the panel by the pane it opened (kept in the plugin state folder, `$HERDR_PLUGIN_STATE_DIR`), as well as by its terminal title, so a panel that is still starting or lost its title is closed rather than doubled; a panel closed by hand is forgotten and the next toggle opens a new one. Toggles run one at a time, so two quick presses never open two panels in a tab. When the panel does not open, Herdr shows a notification.
- Ctrl-click a `.md` report path or a GitHub pull request URL to open it in a popup.
- After a Herdr restart it reopens next to the orchestrator and rewrites the sidebar tokens; a lane whose worktree you remove by hand is closed.
- It only reads, except `[x]` and `[clear all]` on closed lanes, which go through `lane.sh clear`. Lane files are still written only by `lane.sh`, answers still go through the orchestrator, and the only thing it stores is the pane id of the panel it opened.
- Clicking the buttons depends on Herdr passing mouse clicks to the pane (`ui.mouse_capture`); the keys always work. The sidebar filters (`f`, `n`, `F`) need `nc` with Unix-socket support.

## Surviving a compaction

The orchestrator is one long chat. When the client compacts it, the conversation is summarised and details are lost, so nothing the orchestrator needs may live only in the chat:

- **Lane facts** go in the lane file: `lane.sh note` (a follow-up sent to a node, scope you added, a brief or file path) and `lane.sh done-extra` (a done criterion beyond the pattern's, such as "merged to main and this window runs the new plugin version"; `--met N` marks it).
- **Session facts** go in the session file, `${XDG_STATE_HOME:-~/.local/state}/herdr-graph/sessions/<name>.yaml`, written only by `session.sh`: the orchestrator's pane and scratch folder, your standing answers that have no file of their own (such as the worktree approval), lanes queued at the agent limit with their prepared brief, renames, notes and scratch files. One file per orchestrator and per user, because lanes span repositories. Text that looks like a token, key or password is refused.
- **`resume.sh`** prints all of it in one block: every open lane of every repository with lanes (nodes, agents live or gone, open question, pull requests, done checks, notes) with its next action, then the queue, the standing answers, and the standing kind and dialog choices that `kind.sh --remember` and the orchestrator keep in `<scratch>/graph-kinds` and `<scratch>/graph-dialogs`, renames, notes and files. The orchestrate skill runs it first after a compaction or in a new session, then re-starts `herdr:listen` for every live agent.

**Claude Code** does this by itself through the plugin's hooks (`hooks/hooks.json`): `PreCompact` writes a fresh block to `<session folder>/<name>.resume.md`, and `SessionStart` with the `compact` matcher puts the block back into the chat. Both do nothing outside the orchestrator's pane (the session whose `pane` is `$HERDR_PANE_ID`) and never fail the chat. To compact by hand, give the summary a focus:

```text
/compact Keep: that I am the graph orchestrator (herdr-graph-engineering:orchestrate), my session name, and every user decision not yet written with lane.sh or session.sh. Lane and session state is in the files: after compacting, run resume.sh and follow it.
```

**Codex and OpenCode** have no such hook here: after a compaction or in a new session, run `bash <plugin>/scripts/resume.sh` (or start the orchestrate skill again, which runs it first).

## Tests

```bash
bash plugins/herdr-graph-engineering/tests/run-tests.sh
```

Hermetic: throwaway repositories and a stub `herdr`; no live session.

## Next

## Measuring

Run it on 10 to 20 real ideas, then `measure.sh` (or ask the orchestrator "how did the lanes go"): per lane the outcome, minutes, retries, questions to you and failures, and totals per pattern. Judge by the end state: did the lanes finish, how often were you asked, did retries run out. Remove a part (a node, a pattern, a check) that does not earn its place.
