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
| `concurrency` | Judgement for many lanes at once: lanes that edit the same files, folding an ask into a running lane, merge order, merging `origin/main` in, version bumps across parallel pull requests, one writer per checkout, a cap only when you ask for one. Guidance only, no state |
| `feedback-loop` | Turns the feedback loop on or off for the session (off by default): before a lane is cleaned up, the orchestrator and the lane's agents note how the whole flow could have been better; and how the repository's documentation could have helped more; general lessons, never task details, become improvement pull requests to this plugin or to that documentation |

## Concepts

| | |
|---|---|
| **Lane** | One idea. One Herdr workspace (labelled with the lane name), one branch. |
| **Pattern** | A small YAML graph: `agent`, `gate`, `human` and `pr` (`pr: draft`: the orchestrator pushes the branch and opens or updates the draft pull request at that point) nodes; `needs`, `when` and `retry` (with a `max`) edges; `done` checks. Frozen: no other keys, no expressions. |
| **Role** | The brief an agent node gets: Markdown with frontmatter (`name`, `description`, `kind` preference list, `access`). The orchestrator sends its body, then a `## Brief` section for the node (checkout and base, goal, numbered asks, your constraints, the exact gate command, notes), in the shape of [`references/brief-format.md`](references/brief-format.md): a recommended template, not a strict schema. |
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
lane.sh new|show|list|node|retry|ask|answer|note|done-extra|set|close|clear|restore   the only writer of lane files
session.sh set|add|del|show|find                       the only writer of the orchestrator's session file
resume.sh [--fetch] [--out FILE]                        everything the orchestrator needs after a compaction, one block
autocompact.sh [print|check] [--pct N] [--write]          compact the orchestrator at 40% of its context: how, per client; is it on
ready.sh --lane L                                       which nodes can start now
kind.sh --role R [--not K] [--without K] --list|--kind K|--remember K   the installed kinds (recommended first), the chosen one's arguments, standing choices
gate.sh --lane L --node N --pane P [--detach]           run a gate in a visible tab; the tab records its own result
gate.sh --wait | --collect --lane L --node N            block until a gate finishes; record a finished one after the fact
close-done.sh --lane L [--dry-run]                      close the tabs of finished agent and gate nodes (CLOSE/KEEP per node)
cleanup.sh check | run --lane L                          find lanes ready for cleanup and ask; clean one up after your yes
feedback.sh state|add|due|lesson|lessons|used|show|sanitize   the feedback loop: raw notes outside every repository; the sanitiser that refuses task details (--target plugin|repo keeps the plugin's lessons and a repository's documentation lessons apart; --strict for the latter)
status.sh [--text|--line|--json]                        the picture of every lane (display, tab bar), lane files plus live agents
drift.sh [--repo R] [--quiet] [--gate-stall M]          where lane files, live agents and gates disagree, with the command to fix it
check-pattern.sh (FILE | --name P)                      validate a pattern
make-review-stack.sh --pr URL --pr URL ... --out FILE    the graph for reviewing related pull requests
review-owner.sh --pr URL                                the open lane (any repository) and live agent that own a reviewed pull request
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

## Gates

A gate node's command runs in its own tab through `gate.sh --exec`, not typed bare into the shell:

- **It records itself.** The tab's process records `pass` or `fail` with `lane.sh` when the command ends, so an orchestrator that is interrupted, or whose background call ended, loses nothing. `gate.sh --wait` blocks until it finishes (exit 5 on its timeout: still running, wait again); `gate.sh --collect` records a run after the fact, from its heartbeat or else the `GATE <node> <run> EXIT=<n>` line in the tab.
- **It shows that it is alive.** A heartbeat, `<git common dir>/herdr-graph/gates/<lane>/<node>.json`, and the output log next to it hold the start time, the process id, the exit code and the counts. The panel and `status.sh` show a running gate as `tests: running 12m 04s · 340 ok · 2 FAIL · last: <its last output line>`. A gate whose process is gone without an `EXIT` line, whose output stopped for `HERDR_GRAPH_GATE_STALL` minutes (default 10), or that finished without a record goes under NEEDS YOU, and `drift.sh` prints the command that fixes it.
- **Nothing interactive.** The command runs with `PAGER=cat`, `GIT_PAGER=cat`, `MANPAGER=cat`, `GIT_TERMINAL_PROMPT=0` and stdin from `/dev/null`, so a `git grep` cannot stop in `less`. It runs in `bash -c` in the tab's directory, not in your interactive shell.
- **It reports what it changed.** `git status` before and after: a gate that changes the checkout (a fixture's file mode, a generated file) says so in its result (`GATE CHECKOUT CHANGED tests: M path | restore: git -C DIR checkout -- path`) and in the lane record, and `cleanup.sh` names it when a dirty checkout blocks a cleanup.
- **It names its failures.** Lines starting `FAIL` or `not ok` are counted and kept in the heartbeat (`failed`), so a gate on a repository whose base already fails can be compared with the base's failures.

## When a lane file is behind

A lane file changes only when the orchestrator records a node, and it records what it is listening to. So the picture does not trust the file alone. For every node recorded `running`, `status.sh` (and the panel through it) looks at its agent in Herdr:

- blocked: NEEDS YOU, "blocked, waiting for an answer on its screen";
- gone from Herdr: NEEDS YOU, "agent gone";
- idle or done with a last line `NODE <node> RESULT: question <ref>`: NEEDS YOU, with the agent's question as the lane's question (the panel's answer popup relays your answer);
- idle or done with `RESULT: pass|fail <ref>`: NEEDS YOU, "finished: pass ...; check and record" (the orchestrator still checks the evidence before it records a pass);
- idle with no RESULT line: NEEDS YOU, "stopped without a RESULT line".

`status.sh` never reads a screen: `drift.sh` reads the finished agents' screens and caches the RESULT lines in `<git common dir>/herdr-graph/live.json`, and a cached line counts only while the agent stays in the state it was read in. The panel runs `drift.sh --quiet` in the background every 10 seconds; the orchestrator runs `drift.sh` after every listen event and before every report, and records what it prints (`DRIFT <lane>/<node> ... | <lane.sh command>`, or `NO DRIFT`).

A lane whose own pull request merged (its recorded `pr`, a node's pull request, or the one for its branch, from `prs.sh`'s cache) shows under NEEDS YOU as "PR #N merged, waiting for cleanup confirmation" until the cleanup is confirmed or declined.

## Cleanup after a lane

The orchestrator does not wait for you to notice a merge. Before every report and after a lane is done it runs `cleanup.sh check`. A done lane is ready for cleanup when its pull request is merged (the recorded one, else the one for its branch), its checkout is clean and nothing in it is unpushed; a report lane is ready once nothing is unpushed. A review lane (pattern `review`, a review stack, or branch `look/pr-<n>`) never waits for the reviewed pull request: it is ready, even before it is marked done, once it posted, you decided not to post, or its findings were forwarded. When the reviewed pull request belongs to another open lane (its branch is the pull request's head branch, in any repository with lanes; `review-owner.sh --pr URL` prints `OWNER <repo> <lane> <agent|-> <node|->`), `cleanup.sh check` prints a `FORWARD` line and the close question first asks: "Send the N findings of review X to <lane>/<agent>?". On yes the orchestrator prompts that agent with the summary's "Prompt for AI Agents" block, reopens the owner's node as running, and records `forwarded: <lane>/<agent>` on the review lane (`declined` on a no), so it is not asked again. A ready lane goes under NEEDS YOU with a cleanup question and a Herdr notification, and `status.sh --text` (and the panel) shows `cleanup: ready`. Nothing is removed until you say yes and the orchestrator records it (`cleanup: confirmed`; `cleanup.sh run` refuses without it); then `cleanup.sh run` closes the lane's tabs, removes the worktree with `herdr worktree remove` (never `--force`) and closes the lane. The branch is kept. A merged lane with a dirty checkout or unpushed commits is never removed: it goes under NEEDS YOU with the reason. A no is remembered (`cleanup: declined`).

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
- Actions to bind in your Herdr config (`[[keys.command]] type = "plugin_action"`): `herdr-graph-engineering.graph.toggle` (`install-keys.sh` binds it to PREFIX then Alt+G), `.refresh`, `.next-needs-me`.
- Toggle finds the panel by the pane it opened (kept in the plugin state folder, `$HERDR_PLUGIN_STATE_DIR`), as well as by its terminal title, so a panel that is still starting or lost its title is closed rather than doubled; a panel closed by hand is forgotten and the next toggle opens a new one. Toggles run one at a time, so two quick presses never open two panels in a tab. When the panel does not open, Herdr shows a notification.
- Ctrl-click a `.md` report path or a GitHub pull request URL to open it in a popup.
- After a Herdr restart it reopens next to the orchestrator and rewrites the sidebar tokens; a lane whose worktree you remove by hand is closed.
- It only reads, except `[x]`, `[clear all reviews]` and `[clear all]` on closed lanes, which go through `lane.sh clear`, and `[restore]`, which goes through `lane.sh restore`. Lane files are still written only by `lane.sh`, answers still go through the orchestrator, and the only thing it stores is the pane id of the panel it opened.
- It never filters Herdr's sidebar (older versions did, with `f`, `n` and `F`); at start it clears a filter such a version may have left, through `nc -U` when `nc` is there. `.refresh` reaches open panels as the private sequence `ESC [ 99 ~`, which no key sends.

## Feedback loop

Off by default. `/herdr-graph-engineering:feedback-loop` turns it on or off for one orchestrator session (it asks with the client's question tool where there is one, in plain text otherwise), and the orchestrator asks the same once at its start. The choice is stored in the session file (`session.sh set --key feedback --value on|off`), so it survives a compaction; the resume block shows it as `FEEDBACK LOOP: on|off`.

When it is on:

1. **Before a lane is cleaned up**, `cleanup.sh check` prints `FEEDBACK <lane>` and `cleanup.sh run` refuses (`FEEDBACK DUE`) until the orchestrator has asked the lane's still-live agents how the whole flow (pattern, roles, briefs, gates, reviews, panel, scripts, the orchestrator's behaviour) could have been better, and written its own note. `feedback.sh add` keeps these raw notes in `${XDG_STATE_HOME:-~/.local/state}/herdr-graph/sessions/feedback/<session>.yaml`, outside every repository.
2. **Notes become lessons.** The orchestrator writes general lessons from the notes with `feedback.sh lesson`, which stores one only when the sanitiser finds no task detail in it.
3. **Lessons become pull requests.** Every few lessons, at the end of a session, or when you ask, the orchestrator offers an improvement lane in the plugin's own repository. Its brief is the open lessons (`feedback.sh lessons`) and nothing else; it changes only the plugin's instructions, skills, roles, patterns, references and scripts. Its commit messages and pull request body must pass `feedback.sh sanitize` before the pull request opens, and you merge it as any other. Lessons about the repository the lanes worked in go to that repository's documentation instead (below).

### Lessons about the repository

The loop has a second target besides the plugin: the documentation of the repository a lane worked in. Before cleanup, the agents and the orchestrator are also asked how that repository's `AGENTS.md`, `CLAUDE.md`, READMEs and docs could have helped more: guidance that was missing or wrong, rules agents kept tripping over, context that was hard to find, places where agents read too much or too little (context to trim, split or point to), commands that did not work as documented. These notes and lessons carry `--target repo --repo R` and are kept apart from the plugin's: `feedback.sh lessons` lists the plugin's, `feedback.sh lessons --target repo --repo R` that repository's, and each improvement lane gets only its own.

A repository's improvement lane runs in that repository, follows its own rules for branches, commits, checks and pull requests, and edits only its documentation (`AGENTS.md`, `CLAUDE.md`, READMEs, docs), never code, configuration or tests. The bar is higher: a repository lesson must be a general improvement that helps other tasks there ("the agent instructions should say how to run a single test and where its output goes"), never the task, ticket, pull request, branch, service-specific bug or data that produced it. `feedback.sh lesson --target repo` checks it with `--strict`, which also refuses identifiers (`snake_case` words, words with digits) and any inline code; the pull request body and commits pass `feedback.sh sanitize --strict`, and the orchestrator reads the diff.

### The no-leak rule

What reaches a repository is the general lesson, never a detail of a task: "a gate's result was lost when the caller died", not which repository, service, branch, file, pull request or person it happened to. Raw notes never leave the state folder, and the improvement lane's agent never sees them, so it cannot copy a detail it was never given.

`feedback.sh sanitize` refuses (exit 3, one `LEAK <kind> line N: <what>` per finding) text that holds a link, an email, an `@handle`, a token or key, a `#number`, issue, pull request or ticket number, a long number, a commit id, an IP address, a path or branch (anything with `/` or `~`, except the plugin's own files), a file or domain name (except the plugin's own files), code (a fenced block, an inline code span that does not start with a plugin script or `herdr`/`git`/`gh`/`jq`/`yq`/`bash`, braces, `==`, `&&`, `$(`), quoted words (double or curly quotes, a quoted phrase in single quotes, a `>` quote line), a capitalised name in the middle of a sentence or a CamelCase word anywhere, and every denied word. Denied words are the names of the lanes and the repositories in the session's notes and queue (for each repository: its folder name, its remote's owner and name, its branches, its commit authors), plus `--repo DIR` and `--deny WORD`. `--strip` drops the leaking lines instead and refuses only when none is left.

### What the sanitiser cannot catch

It is a conservative pattern check, not an understanding of the text. It refuses rather than guesses, so it also refuses some harmless text (a sentence with a long number, a capitalised word mid-sentence); rewrite the lesson more generally. It cannot know:

- a name written in lower case that is not a denied word (a service or product named by a common word), or a capitalised name at the start of a sentence that is not an author of a repository it was given;
- a description precise enough to identify the task without naming it ("the payments retry bug from last week");
- a detail spelled to slip past it (a name split up, a paraphrased quote);
- anything in the diff itself: it checks the lessons, commit messages and pull request body, not code or instruction changes.

So the orchestrator also reads the improvement lane's diff for task details before its pull request opens, and you review it before merging.

## Surviving a compaction

The orchestrator is one long chat. When the client compacts it, the conversation is summarised and details are lost, so nothing the orchestrator needs may live only in the chat:

- **Lane facts** go in the lane file: `lane.sh note` (a follow-up sent to a node, scope you added, a brief or file path) and `lane.sh done-extra` (a done criterion beyond the pattern's, such as "merged to main and this window runs the new plugin version"; `--met N` marks it).
- **Session facts** go in the session file, `${XDG_STATE_HOME:-~/.local/state}/herdr-graph/sessions/<name>.yaml`, written only by `session.sh`: the orchestrator's pane and scratch folder, your standing answers that have no file of their own (such as the worktree approval), lanes queued at the agent limit with their prepared brief, renames, notes and scratch files. One file per orchestrator and per user, because lanes span repositories. Text that looks like a token, key or password is refused.
- **`resume.sh`** prints all of it in one block: every open lane of every repository with lanes (nodes, agents live or gone, what a finished agent printed as its RESULT line (it runs `drift.sh --quiet` first), open question, pull requests, done checks, notes) with its next action, then the queue, the standing answers, and the standing kind and dialog choices that `kind.sh --remember` and the orchestrator keep in `<scratch>/graph-kinds` and `<scratch>/graph-dialogs`, renames, notes and files. The orchestrate skill runs it first after a compaction or in a new session, then re-starts `herdr:listen` for every live agent.

**Claude Code** does this by itself through the plugin's hooks (`hooks/hooks.json`): `PreCompact` writes a fresh block to `<session folder>/<name>.resume.md`, and `SessionStart` with the `compact` matcher puts the block back into the chat. Both do nothing outside the orchestrator's pane (the session whose `pane` is `$HERDR_PANE_ID`) and never fail the chat. To compact by hand, give the summary a focus:

```text
/compact Keep: that I am the graph orchestrator (herdr-graph-engineering:orchestrate), my session name, and every user decision not yet written with lane.sh or session.sh. Lane and session state is in the files: after compacting, run resume.sh and follow it.
```

**Codex and OpenCode** have no such hook here: after a compaction or in a new session, run `bash <plugin>/scripts/resume.sh` (or start the orchestrate skill again, which runs it first).

### Compacting at 40%

The orchestrator compacts by itself at 40% of its context: early and often, so the chat stays fast and the files carry the state. A plugin cannot set this (Claude Code reads it only from its environment or a settings file's `env`, and plugins ship neither), so `autocompact.sh` prints how and checks it, and writes only with `--write`:

| Client | Setting | Scope it to the orchestrator |
| --- | --- | --- |
| Claude Code | `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40` (documented: the percentage of the auto-compact window at which auto-compaction triggers; it only lowers the threshold) | start only the orchestrator with it, or `autocompact.sh --write` puts it in `<folder>/.claude/settings.local.json` of the folder the orchestrator starts in (backup first; the home folder, which would be the global settings, is refused) |
| Codex | `model_auto_compact_token_limit` (a token count: 40% of the model's window, `--window`) | `codex -c model_auto_compact_token_limit=N` for the orchestrator only |
| OpenCode | `compaction.buffer` (the share kept free before automatic compaction: `"60%"`) | the `opencode.json` of the folder the orchestrator starts in |

The orchestrate skill runs `autocompact.sh check` at the start and offers the user the step once when it is off. Lane agents keep the default. In Claude Code the `PreCompact` hook has no matcher, so it runs on an automatic compaction as on `/compact`, and `SessionStart` with `compact` brings the block back either way.

## Tests

```bash
bash plugins/herdr-graph-engineering/tests/run-tests.sh
```

Hermetic: throwaway repositories and a stub `herdr`; no live session.

## Next

## Measuring

Run it on 10 to 20 real ideas, then `measure.sh` (or ask the orchestrator "how did the lanes go"): per lane the outcome, minutes, retries, questions to you and failures, and totals per pattern. Judge by the end state: did the lanes finish, how often were you asked, did retries run out. Remove a part (a node, a pattern, a check) that does not earn its place.
