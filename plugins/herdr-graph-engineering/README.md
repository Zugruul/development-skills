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
| `display` | Read-only picture of every lane: `NEEDS YOU`, `WORKING`, `DONE`, each with its node chain, retries, open question and file references |

## Concepts

| | |
|---|---|
| **Lane** | One idea. One Herdr workspace (labelled with the lane name), one branch. |
| **Pattern** | A small YAML graph: `agent`, `gate` and `human` nodes; `needs`, `when` and `retry` (with a `max`) edges; `done` checks. Frozen: no other keys, no expressions. |
| **Role** | The brief an agent node gets: Markdown with frontmatter (`name`, `description`, `kind` preference list, `access`). |
| **Lane file** | `<git common dir>/herdr-graph/<lane>.yaml`: only what Herdr and git cannot show (idea, graph copy, approved gate command, node results, retries, open question, owner, history). Written only by `lane.sh`, under a lock. |

Patterns and roles are looked up in the repository's `.herdr-graph/patterns|roles/`, then `~/.config/herdr-graph/patterns|roles/`, then this plugin. To add a kind of work, add a pattern; to add an agent, add a role. No skill changes.

Shipped patterns:

| Pattern | Graph |
|---|---|
| `solo` | implementer → tests gate (retry up to 3) → draft pull request |
| `pair` | the same, then a read-only reviewer of another kind; `changes` sends the work back to the implementer (up to 2) |
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
lane.sh new|show|list|node|retry|ask|answer|set|close   the only writer of lane files
ready.sh --lane L                                       which nodes can start now
kind.sh --role R [--not KIND]                           the kind and arguments for a role here
gate.sh --lane L --node N --pane P                      run a gate in a visible tab, record its exit code
close-done.sh --lane L [--dry-run]                      close the tabs of finished agent and gate nodes (CLOSE/KEEP per node)
cleanup.sh check | run --lane L                          find lanes ready for cleanup and ask; clean one up after your yes
status.sh [--text|--line|--json]                        the picture of every lane (display, tab bar)
check-pattern.sh (FILE | --name P)                      validate a pattern
make-review-stack.sh --pr URL --pr URL ... --out FILE    the graph for reviewing related pull requests
check.sh                                                inside Herdr?
panel.sh / panel-action.sh / popup.sh                   the Herdr panel, its actions and popups
measure.sh [--json]                                     how the lanes went: outcome, minutes, retries, questions
```

## When a node's tab closes

Every agent and gate node runs in its own tab, recorded in the lane file (`lane.sh node --tab`). After each node record and at lane done the orchestrator runs `close-done.sh`, which decides from the lane's graph:

- an agent tab closes once its node is `done` and passed, no `retry` edge that has not passed can still send work back to it (an implementer stays until its gate and reviewer pass), and no `human` node after it is still undecided (a reviewer stays until `approve`, so it can be asked about its draft);
- a gate tab closes once its result is recorded as passed; a failed gate stays visible until the retry runs;
- at lane done or close, every agent and gate tab of the lane closes.

Never closed: a tab not recorded for a node, a running or blocked node, an agent Herdr shows working or blocked, the first tab of the lane's workspace, a tab outside it. The worktree stays until you agree to cleanup.

## Cleanup after a lane

The orchestrator does not wait for you to notice a merge. Before every report and after a lane is done it runs `cleanup.sh check`. A done lane is ready for cleanup when its pull request is merged (the recorded one, else the one for its branch), its checkout is clean and nothing in it is unpushed; a review lane (branch `look/pr-<n>`) is ready once it is done, and a report lane once nothing is unpushed. A ready lane goes under NEEDS YOU with a cleanup question and a Herdr notification, and `status.sh --text` (and the panel) shows `cleanup: ready`. Nothing is removed until you say yes; then `cleanup.sh run` closes the lane's tabs, removes the worktree with `herdr worktree remove` (never `--force`) and closes the lane. The branch is kept. A merged lane with a dirty checkout or unpushed commits is never removed: it goes under NEEDS YOU with the reason. A no is remembered (`cleanup: declined`).

## What the orchestrator may do alone

Start agents and gates, retry within a pattern's limit, commit, push the lane branch, open a **draft** pull request. It asks before marking a pull request ready, posting anywhere, or touching anything outside the lane. It never merges, approves, force-pushes or deletes a branch.

## The Herdr panel

The folder is also a Herdr plugin (`herdr-plugin.toml`): a graph panel next to the orchestrator, installed into Herdr separately:

```bash
herdr plugin install Zugruul/development-skills/plugins/herdr-graph-engineering   # or: herdr plugin link <this folder>
```

```text
 Graph                       [◷ 5s] [↻]
----------------------------------------
 NEEDS YOU (1)
 ▸ why-slow  investigate
     investigate ?
     ? Staging or production?

 WORKING (1)
   task-x  solo
     impl ✓ → tests ⟳ 1/3

 updated 10:42:07 · every 5s · ⏎ go · a answer · d detail · ? keys
```

- `/herdr-graph-engineering:display` opens or closes it. Without the Herdr plugin, `display` prints the same picture as text.
- Refresh: automatic, every 5s by default (`refresh=10s` in `$(herdr plugin config-dir herdr-graph-engineering.graph)/config` changes the start); `[◷ 5s]` or `t` cycles 5s, 10s, 15s, 30s, 1m, 5m; `[↻]` or `r` refreshes now. The footer says when it last read.
- Keys: ↑↓ select a lane; enter jumps to its agent (the blocked one first); `a` answers its question in a popup (the answer goes to the orchestrator chat, which relays it); `d` lane detail; `f` only this lane's agents in Herdr's sidebar, `n` only the agents that need you, `F` all again; `q` closes it.
- Actions to bind in your Herdr config (`[[keys.command]] type = "plugin_action"`): `herdr-graph-engineering.graph.toggle`, `.refresh`, `.next-needs-me`.
- Ctrl-click a `.md` report path or a GitHub pull request URL to open it in a popup.
- After a Herdr restart it reopens next to the orchestrator and rewrites the sidebar tokens; a lane whose worktree you remove by hand is closed.
- It only reads. Lane files are still written only by `lane.sh`, answers still go through the orchestrator, and it stores nothing: it finds its own pane by its terminal title.
- Clicking the buttons depends on Herdr passing mouse clicks to the pane (`ui.mouse_capture`); the keys always work. The sidebar filters (`f`, `n`, `F`) need `nc` with Unix-socket support.

## Tests

```bash
bash plugins/herdr-graph-engineering/tests/run-tests.sh
```

Hermetic: throwaway repositories and a stub `herdr`; no live session.

## Next

## Measuring

Run it on 10 to 20 real ideas, then `measure.sh` (or ask the orchestrator "how did the lanes go"): per lane the outcome, minutes, retries, questions to you and failures, and totals per pattern. Judge by the end state: did the lanes finish, how often were you asked, did retries run out. Remove a part (a node, a pattern, a check) that does not earn its place.
