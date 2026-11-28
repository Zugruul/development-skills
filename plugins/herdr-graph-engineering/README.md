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

## Clients

The orchestrator and every lane agent can each be Claude Code, Codex or OpenCode.

| Client | Install |
| --- | --- |
| Claude Code | `claude plugin marketplace add Zugruul/development-skills`, then `claude plugin install herdr-graph-engineering@development-skills` (installs `herdr` too) |
| Codex | `codex plugin marketplace add Zugruul/development-skills`, `codex plugin add herdr@development-skills` and `codex plugin add herdr-graph-engineering@development-skills` (Codex installs no dependency by itself). Then open `/hooks` and trust this plugin's hooks, and again after an update: until then none of them runs |
| OpenCode | a clone, then `./install-skills.sh opencode --global`: the skills, and `opencode/herdr-graph.js` linked into OpenCode's plugin folder. Use `--global`: a lane agent works in a new worktree, which a project install does not reach |

Claude Code and Codex run `hooks/hooks.json`. OpenCode runs no command hooks, so the OpenCode plugin turns its events into the same script calls:

| What | Claude Code | Codex | OpenCode |
| --- | --- | --- | --- |
| A lane agent's result at turn end | `Stop` hook | `Stop` hook | `session.idle` |
| Its question | `AskUserQuestion` hooks | `request_user_input` hooks, where Codex offers that tool; by default it asks in text, which its result line and screen report | `question.*` events |
| Its permission request | `PermissionRequest` hook | `PermissionRequest` hook | `permission.asked` |
| Its client's own error | `StopFailure` hook | **Codex has no such hook**: the lane shows as `stopped` or from its screen, and the orchestrator reads the screen | `session.error` |
| The orchestrator may not leave a question unasked; the AFK reminder | `Stop`, `UserPromptSubmit` hooks | the same hooks | `session.idle`, `chat.message` |
| Waking the orchestrator | the waiter (`asyncRewake`) | **no waiter** (Codex ignores `asyncRewake`): the Herdr plugin's push | the waiter, run by the OpenCode plugin, which sends the message through OpenCode's API |
| The resume block after a compaction | `PreCompact`, `SessionStart` hooks | the same hooks | the compaction events |
| Asking you | `AskUserQuestion` | a numbered block that ends the turn | `question` |
| Closing a finished lane, and its resume command | `claude --resume <id>` | `codex resume <id>` | `opencode --session <id>` |

Closing by itself is the same bash for all three clients. The session id comes from Herdr's `agent_session` field, so it needs a Herdr that reports it for that client.

Without the OpenCode plugin, an OpenCode agent still works: its result file and its screen report (as for any client without hooks), the Herdr plugin wakes an orchestrator when it can read its input box and otherwise notifies you, and `resume.sh` is run by hand. The push types only into an input box it can recognise by its `❯` or `›` prompt; it was not checked against OpenCode's screen, so count on the plugin to wake an OpenCode orchestrator.

For Herdr to read an agent's state natively, also run `herdr integration install <kind>` once for each client.

**Tested** (2026-11, isolated config folders, a local mock model, a stub `herdr`): Claude Code 2.1.332: lane claim from `Stop`. Codex 0.165.0: the hooks loaded, lane claim, the unasked-question block. OpenCode 1.19.4: lane, question and permission claims, the unasked-question block, the waiter, the AFK reminder and the resume block. Not run with a real client: Codex's question, permission and compaction hooks (loaded, documented), and OpenCode's `session.error` (tested with a fake client). The plugin targets OpenCode 1.x; the plugin API that OpenCode's newer documentation describes is not tested.

## Requirements

The `herdr` plugin, the `herdr` binary (the agent runs inside a Herdr pane), `bash` 3.2 or later (macOS default; WSL on Windows), `jq`, `yq` ([mikefarah/yq](https://github.com/mikefarah/yq) v4) and `git`; `gh` for pull requests. No Python. (The OpenCode plugin is JavaScript that only calls the bash scripts; its tests need `node`.)

## Skills

| Skill | Purpose |
|---|---|
| `orchestrate` | The one chat: route ideas into lanes, run each lane's graph, check evidence, retry within limits, relay questions, open a draft pull request when done |
| `display` | Read-only picture of every lane: `NEEDS YOU`, `WORKING`, `DONE` (the panel also lists `CLOSED`), each with its node chain, retries, open question and file references |
| `concurrency` | Judgement for many lanes at once: lanes that edit the same files, folding an ask into a running lane, merge order, merging `origin/main` in, version bumps across parallel pull requests, one writer per checkout, a cap only when you ask for one. Guidance only, no state |
| `afk` | `on`, `off` or `status`: while on, the orchestrator decides the safe things itself, records each, and shows the list when you return. Only this command sets it |
| `auto-merge` | `on` or `off`, for the session, one repository or one lane: while on, the orchestrator may merge a lane's pull request after its gate and reviews pass. Off by default |
| `feedback-loop` | Turns the feedback loop on or off for the session (off by default): before a lane is cleaned up, the orchestrator and the lane's agents note how the whole flow could have been better; and how the repository's documentation could have helped more; general lessons, never task details, become improvement pull requests to this plugin or to that documentation |

## Concepts

| | |
|---|---|
| **Lane** | One idea. One Herdr workspace (labelled with the lane name), one branch. |
| **Pattern** | A small YAML graph: `agent`, `gate`, `human` and `pr` (`pr: draft`: the orchestrator pushes the branch and opens or updates the draft pull request at that point) nodes; `needs`, `when` and `retry` (with a `max`) edges; `done` checks. Frozen: no other keys, no expressions. |
| **Role** | The brief an agent node gets: Markdown with frontmatter (`name`, `description`, `kind` preference list, `access`). The orchestrator sends its body, then a `## Brief` section for the node (checkout and base, goal, numbered asks, your constraints, the exact gate command, notes), in the shape of [`references/brief-format.md`](references/brief-format.md): a recommended template, not a strict schema. |
| **Lane file** | `<git common dir>/herdr-graph/<lane>.yaml`: only what Herdr and git cannot show (idea, graph copy, approved gate command, node results, retries, open question, owner, history). Written only by `lane.sh`, under a lock. |

Patterns and roles are looked up in the repository's `.herdr-graph/patterns|roles/`, then `~/.config/herdr-graph/patterns|roles/`, then this plugin. To add a kind of work, add a pattern; to add an agent, add a role. No skill changes.

Every view (status text and JSON, the panel, the popups, the resume block, `lane.sh list`, the lane type dialog) names a lane by its pattern only when the plugin ships that pattern. Any other graph (hand-written, `--pattern-file`, or a user or repository pattern, also one that reuses a shipped name) shows as `custom` or `custom: <name>`. In `status.sh --json`, `pattern` is that shown type and `pattern_name` is the stored name.

Shipped patterns:

| Pattern | Graph |
|---|---|
| `solo` | implementer → tests gate (retry up to 3) → draft pull request |
| `pair` | the same, then a read-only reviewer of another kind; `changes` sends the work back to the implementer (up to 2) |
| `fast` | urgent fixes, only when you ask (fast, urgent, hotfix, pull request ASAP): the smallest fix with a focused test → the draft pull request opens at once (`pr` node) → tests gate; a failure goes back to the implementer (up to 3) and the fix is pushed to the same pull request |
| `preview` | user-facing changes you want to see first: a read-only plan with an HTML preview → adversarial review (`changes` goes back to the plan, up to 3) → you approve → implementer → tests gate (retry up to 3) → draft pull request |
| `improve` | the feedback loop's improvement lanes only: implementer → tests gate → a read-only reviewer of another kind that checks existing expertise is preserved; `changes` sends the work back (up to 2) |
| `investigate` | a read-only investigator writes a report |
| `review` | a pull request reviewer drafts → you approve → a poster posts one grouped `COMMENT` review whose body is the summary, verified |
| review stack | `make-review-stack.sh` writes the graph for related pull requests: one reviewer each in parallel → a cross-PR check → you approve → one poster each |
| `plan` | a planner drafts a custom graph; you approve it before it runs |
| `adopt` | an agent that already finished, only when you ask to adopt it: one `work` node recorded done → CLOSED |

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
lane.sh new|show|list|node|step|reject|tab-closed|restore-note|retry|ask|asked|answer|withdraw|offer|dismiss|note|done-extra|set|close|clear|restore   the only writer of lane files
session.sh set|add|del|show|find|afk|automerge         the only writer of the orchestrator's session file (decide.sh writes its decisions)
start.sh [--scratch DIR]                                the orchestrator's first command: its session file
notify.sh reconcile|take|push|signal|tick|sweep|list|gate|promptwhat wakes the orchestrator, once, and the push fallback
await.sh [--session S] [--hook [--client claude|opencode]]
                                                        the waiter: ends with the next event, which wakes the chat
hook.sh stop|prompt|ask|ask-done|permission|stop-failure    the client hooks (and the OpenCode plugin's calls): observe lane agents, guard unasked questions
signal.sh herdr                                         the Herdr plugin's event hook
adopt.sh --agent A --idea T --access read|write         watch an agent started outside the graph
decide.sh add|list|digest|seen                          decisions made without you, and the list you see
merge.sh check|run --lane L                             the only way the orchestrator merges (auto-merge on)
resume.sh [--fetch] [--out FILE]                        everything the orchestrator needs after a compaction, one block
autocompact.sh [print|check] [--pct N] [--write]          compact the orchestrator at 40% of its context: how, per client; is it on
ready.sh --lane L                                       which nodes can start now
kind.sh --role R [--not K] [--without K] --list|--kind K|--remember K   the installed kinds (recommended first), the chosen one's arguments, standing choices
gate.sh --lane L --node N --pane P [--detach]           run a gate in a visible tab; the tab records its own result
gate.sh --wait | --collect --lane L --node N            block until a gate finishes; record a finished one after the fact
close-done.sh --lane L [--dry-run]                      close the tabs of finished agent and gate nodes (CLOSE/KEEP per node)
cleanup.sh check | run [--afk] | facts | reopen | remove --lane L  close finished lanes and ask about the rest (check without --repo: every repository); clean one up after your yes (--afk: nine checks); remove a closed lane's worktree when you ask
feedback.sh state|add|due|lesson|lessons|proposed|used|reopen|show|sanitize   the feedback loop: raw notes outside every repository; the sanitiser that refuses task details (--target plugin|repo keeps the plugin's lessons and a repository's documentation lessons apart; --strict for the latter)
guard.sh check --repo DIR --base REF [--allow FILE]     the preservation check: every instruction sentence removed, changed or moved since the base, unless allowed with a reason
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

## Which repositories are shown

Lane files live inside each repository, so the panel, `status.sh`, `drift.sh`, `resume.sh`, `prs.sh`, `review-owner.sh`, the worktree-removed hook and `cleanup.sh check` without `--repo` first find the repositories. They share one function (`lane_repos` in `scripts/src/common.sh`), which adds up:

1. the repository Herdr records for each worktree workspace;
2. the git toplevel of every Herdr pane's folder. A workspace made with `herdr workspace create` (for example on a standalone clone) records no repository, so this is how it is found while a pane is in it;
3. the registry `${XDG_STATE_HOME:-~/.local/state}/herdr-graph/repos`, one primary checkout per line, which `lane.sh new` and `lane.sh restore` write. It keeps a repository visible after its workspaces close;
4. the current folder.

Each repository is listed once, as its primary checkout. A path that is gone or no longer a repository is skipped without an error; its registry line is kept, because a drive may only be away for a while (delete the line to forget it). A lane made before the registry existed is found only through 1, 2 and 4 until a new or restored lane registers its repository. The panel and the orchestrator must see the same `XDG_STATE_HOME`.

Make a lane's checkout with the `herdr:worktree` skill (`herdr worktree create`): it is what Herdr links to the repository, and what cleanup removes with `herdr worktree remove`. A standalone clone is for when you ask for one.

## When a lane file is behind

A lane file changes only when the orchestrator records a node. So the picture does not trust the file alone. For every node recorded `running`, `status.sh` (and the panel through it) looks at its agent in Herdr: blocked, gone, finished, asking, failed or stopped all show under NEEDS YOU.

What a finished agent claims is read in this order (`src/result.sh`):

1. **Its client's hooks** (`hook.sh`, from the Claude Code and Codex hooks and the OpenCode plugin): the last non-empty line of the final message at turn end; the exact question and options of a question dialog; the tool of a permission request; the client's own error. With a hook claim the screen is not read. Background tasks or crons with no result mean "not finished". A new turn drops the old claim.
2. **Its result file**, `<output file>.result.json`: `{node, run, result, ref, final}`. Each start of a node has a run id (`lane.sh node` prints `RUN <id>`); a file of another run or node is ignored.
3. **Its screen**, strictly: only a line that *is* `NODE <node> RESULT: pass|fail|question <ref>` (after spaces or a known bullet) counts (a question only while no newer prompt follows it). Quotes, examples, the brief's template and text after two spaces do not.

`NODE <node> STEP: <name> <pass|fail> <ref>` (or `"final": false`) is a step: it never finishes a node. Every claim shows its source (`# source: stop-hook`); a claim is never proof, and one that does not hold is rejected with `lane.sh reject`, after which that ref is not reported again.

`drift.sh` prints each mismatch with the command that fixes it. It never writes a lane file.

Only a lane's **own** merged pull request counts: the recorded one (`lane.sh set --key pr`, or a pr node's). With none recorded, its branch's, only while no pull request on the branch is open and only if the pull request is newer than the lane, and only for a lane that is done or has no unfinished node. Any other pull request merged on the branch (a side pull request) is only a lane note (`SIDE-MERGE`): it asks nothing. The panel says what is true: "checking cleanup", "waiting for cleanup confirmation" (only once the question is asked), "cleanup blocked: ...", or "merged but the lane is unfinished". A wrong entry can be hidden for that pull request alone (`lane.sh dismiss`).

## Waking the orchestrator

The orchestrator does not poll. It ends its turn and is woken.

```text
fast:   lane agents' hooks · Herdr plugin events · a gate that ends in its tab
slow:   a full sweep every 300 s (the waiter; the panel while it is open; Herdr startup)
            -> notify.sh reconcile: read the facts again, one event per real change
            -> delivery: the waiter (types nothing), else the push onto an empty input box
```

- **An event only means "look".** Hooks, Herdr events and the sweep call one function, so they agree. Only lanes the session owns count.
- **Once.** The key is repository, lane, node, reason, run, record count and ref. A flapping agent does not resend: a state that clears and returns within 60 s is the same event. Recording the node arms it again. "Stopped" must hold for 30 s. Changes within 5 s make one message.
- **The waiter** (`await.sh`) is armed after every turn of the orchestrator, by a Claude Code `Stop` hook with `asyncRewake` or by the OpenCode plugin: it waits in the background, costs no tokens, and when an event is pending it exits 2, which wakes the idle chat. One per session: a newer one takes over. It never touches what you are typing. It survives `/compact`. It ends quietly after 23 h 50 min (Claude kills a hook silently at its 24 h timeout); the push then covers. In Codex the hook returns at once. In OpenCode the plugin sends the message with `promptAsync`.
- **The push** (the Herdr plugin; the only wake for Codex) types the message with `herdr agent prompt` only when no waiter is alive, the orchestrator's pane **and** name still match, it is idle or done, and its input box is recognisably empty (dim placeholder text counts as empty). On a draft, a dialog or an unknown screen it sends you a notification instead. At most one push a minute.
- **The message is short and safe**: `graph: lane/node reason, lane/- reason (reminder 1)`. It carries the fixed prefix, lane and node names and reason codes, never any text of an agent. What to do with it is in the orchestrate skill, "When an event arrives". `hook.sh` knows the watcher's message by this whole shape (`EVENT_MESSAGE_RE`, `src/common.sh`), so your own words starting with `graph:` stay yours.
- **Acknowledge**: `notify.sh ack --session S --lane L [--node N] [--reason R] [--note T]` marks an event handled: no reminder, no second message and no "manual intervention" mark until the lane's facts change (a new RESULT line, a new question, a new gate run, a status change). Writing the lane (a note, `node --status running`) is no change. `lane.sh answer` acknowledges the question it answers. An acknowledgement of evidence that carries no write time (a screen, Herdr's state) also ends when the agent is seen working again; a result file or hook claim written again is new by its time. So an agent that works and stops again between two looks, with the very same screen line, is not reported again.
- **Stopped means nothing runs**: an idle agent whose status line shows background work is not stopped. Claude Code: "N shell(s) still running", a shell, monitor or background task in the footer, "Waiting for N background agent". Codex: "N background terminal(s) running · /ps to view · /stop to close" ([`unified_exec_footer.rs`](https://github.com/openai/codex/blob/main/codex-rs/tui/src/bottom_pane/unified_exec_footer.rs)). The Claude Code footer texts are from what its screen showed, not from its documentation. For OpenCode no status text for background work is known, so none is detected.
- **An answered question is no question**: a screen's `RESULT: question` line followed by a newer prompt (a line starting `❯` or `›`, above the input box) counts no more. Other prompt styles (OpenCode) are not recognised; there `lane.sh answer` keeps it quiet.
- **A quiet gate is stalled only when idle.** Past `--gate-stall` minutes without output, `status.sh` measures the CPU time of the gate's process tree for `HERDR_GRAPH_CPU_SAMPLE` seconds (1). At a tenth of a core or more it is still working, and its progress line says "using the CPU". It reads `/proc` (ended children count, so many short compiler runs do); without it (macOS) `ps`, which sees only live processes. Work outside the tree (a build daemon, a container, a remote runner) does not count.
- **The sweep interval is 300 s** (`HERDR_GRAPH_SWEEP`). Events carry everything that has an event; the sweep only covers what has none: pull request merges, stalled or lost gates, events lost while the plugin was off or Herdr restarted, and what auto-merge can merge. 300 s keeps `gh` calls low and bounds a missed change to five minutes. Reminder times are checked against stored timestamps, not by the sweep.
- **Reminders**: after 5 and 15 minutes unhandled, to the orchestrator and as a Herdr notification; with the second one, at 15 minutes, the lane is marked **‼ needs manual intervention** in the panel. A question waiting for you reminds only you. Herdr shows no notification with its default config (`shown: false`); `notify.sh list` says so.
- **Questions** are put to you at once, in a dialog, one decision per question. A lane keeps every open question. Answering one never sends a node with a live agent back to `waiting`. The `Stop` hook (or the OpenCode plugin) refuses (once) to end a turn that leaves a question unasked.

**The lane hooks only observe.** The plugin's hooks load in every chat where the plugin is enabled. In a pane that is neither a lane agent's nor the orchestrator's they exit after one file test. In a lane pane they print nothing, decide nothing and always exit 0. No hook guards or blocks a command.

Both parts must be installed and current: the client's plugin (hooks or OpenCode plugin, waiter) and the Herdr plugin (events, push, panel), which is installed and updated separately. Codex asks you to review and trust plugin hooks; until then only the sweep, result files and screens report for Codex agents.

## AFK

`/herdr-graph-engineering:afk on|off|status`. Off until that command turns it on; the orchestrator never asks. Default scope: tiers 1 and 2, all lanes, queued ideas (still only under a standing worktree approval), no worktree removal, until you return. `on cleanup` ticks worktree removal.

| | |
|---|---|
| Tier 1, alone | start a ready node, retry within limits, record a checked result, answer an agent only from your quoted words, prompt a stopped agent once, close finished tabs, push the lane branch and open or update a draft pull request, start a queued idea |
| Tier 2, only if a fresh read-only agent of another kind agrees | a choice a commit can undo, replacing a failed agent, rerunning or stopping a gate |
| Tier 3, always waits | approve, mark ready or merge (except auto-merge), force-push, posting, deleting or removing (except the checked removal), `human` nodes, secrets, installs, permission prompts, new repositories or gate commands, going past a limit, adopting |

Each decision is recorded **before** it is acted on (`decide.sh`, which refuses tier 3, a tier 2 without its second-opinion file and an answer without its source). While something waits no dialog is opened; the other lanes go on. When you send a message, you first see "Decided while you were away" (with what can and cannot be undone), then you are asked "still away?". AFK cannot answer the orchestrator's own permission prompts. These are written rules: no hook blocks a command.

**AFK worktree removal** (`cleanup.sh run --afk`) happens only when all nine hold: AFK on with `cleanup`, for this lane; the lane done with every extra criterion; a recorded pull request that `gh` says is merged from the lane's branch; no changed or untracked file and no commit beyond its head; no ignored file except build output (`target/`, `node_modules/`, `build/`, plus the lines of `~/.config/herdr-graph/safe-to-lose`); no working or blocked agent and no other agent or lane in the folder; no other open question and feedback collected; a linked worktree, not a main checkout or an adopted one; `herdr worktree remove` without `--force`. It is never done for review or report lanes, or merged-early, blocked, kept or dismissed ones. It is recorded as partly reversible.

## Auto-merge

`/herdr-graph-engineering:auto-merge on|off`, for the session, a repository or a lane (the narrowest setting wins; plain `off` turns every one off). Off by default; a new session starts off. Only `merge.sh` merges: the lane's recorded pull request, never a review lane's; no open question; every node passed, with at least one gate; the gate and each review passed on the pull request's head commit; the checkout clean and pushed; no requested changes or missing required review; no conflict; every CI check passed. It **marks a draft ready first** (GitHub merges no draft), merges only that commit (`--match-head-commit`), never uses `--admin` or `--auto`, never deletes a branch, and records the merge for you like an AFK decision.

## Adopting an agent

`adopt.sh --agent A --idea T --access read|write` makes a one-node lane around an agent you started yourself. It refuses an agent a lane already records and a second writer in a checkout, records no tab (so nothing closes it), keeps a read adoption's `HEAD` and status as its baseline, and sends the agent the result protocol once, when it is not blocked. Cleanup of an adopted lane closes the record only.

Agents are adopted only when you ask: the ones you name, and for "all" the orchestrator shows the list and gets your yes first. `adopt.sh` is for an agent still at work. For one that already finished, the orchestrator checks its evidence, sends it nothing and records it with the `adopt` pattern, without a branch, workspace or tab, straight to CLOSED. An agent in a folder outside git cannot be adopted.

## Cleanup after a lane

The sweep runs `cleanup.sh check`, as does the orchestrator before every report.

**A finished lane closes by itself.** It is finished when its recorded pull request is merged and every node is done or skipped (its status may still be open), or when it is a finished review lane with no findings left to forward. Only removing the worktree waits for you.

- It records a **restore note** in the lane file: the checkout, and each agent's session id and resume command, from `herdr agent get` (`close-done.sh` also keeps them before it closes a tab). It then runs `herdr workspace close` (never `--group`), so the agents leave Herdr's agent list. The worktree and the branch are kept.
- The workspace stays open when it is not the lane's alone: another agent or open lane in it, the caller's or an orchestrator's own workspace, or no linked worktree. An adopted lane only has its record closed.
- An unmet extra done criterion does not hold the lane. It is listed as open in the lane note and on the panel's CLOSED entry. Uncommitted or unpushed work stays in the kept worktree, and the note names it.
- It waits (`AUTOCLOSE-WAIT`) while an agent is working or blocked, a question is open, or Herdr refuses. Only a blocked agent puts the lane under NEEDS YOU by itself. With the feedback loop on, it waits for the orchestrator's note (event `feedback-due`).
- **Turn it off** for a session (default on): `session.sh set --key autoclose --value off`. It is stored in the session file, with the other toggles. A lane uses the setting of the orchestrator that owns it.
- **Restore** (the panel's `[restore]`, or `lane.sh restore`) brings the record back and shows each resume command: `claude --resume <id>`, `codex resume <id>` or `opencode --session <id>`. A restored lane never closes by itself again. Run the command in the kept worktree. Where Herdr reports no session id for an agent, no command is shown.
- **Remove** the worktree with the panel's `[x]` on the CLOSED lane, or ask the orchestrator (`cleanup.sh remove --lane L`). It never uses `--force`. It refuses a dirty checkout, a busy or foreign agent in it, a branch an open lane uses, and ignored files that would be lost (`--lose-ignored` only after your yes). A main checkout and an adopted lane's checkout are never removed. The branch is kept.
- **Limits.** A pull request lane in an active AFK removal scope does not close by itself: AFK removes it with its nine checks. A lane you kept, or confirmed for removal, does not either.

Where auto-close does not apply (it is off, or the lane has no recorded pull request), the lane is asked about. A done lane is ready when its own pull request is merged, its checkout is clean and nothing in it is unpushed; a report lane once nothing is unpushed; a review lane (pattern `review`, a review stack, or branch `look/pr-<n>`) once it posted, you decided not to post, or its findings were forwarded. When the reviewed pull request belongs to another open lane, the orchestrator first asks whether to send it the findings.

- **Asked per lane.** One lane at a time, one question per topic, each with a preview (`cleanup.sh facts`): the pull request, the worktree, the kept branch, ignored files that would be lost, tabs. Remove, not now, keep, or "this entry is wrong".
- **Ignored files count.** Git calls a checkout clean while it holds a `.env`, and `herdr worktree remove` deletes it. Ignored files outside build folders are named in the question.
- **A yes covers what was shown.** If the pull request, head or checkout changed, `run` refuses and the question is asked again. A question that no longer holds is withdrawn.
- **Merged early** (the lane's recorded pull request merged, a node unfinished) is its own question: keep working, finish, or dismiss. Never "cleanup".
- Nothing is removed until you say yes and it is recorded (`cleanup: confirmed`), except the AFK removal above. `cleanup.sh run` closes the tabs, removes the worktree with `herdr worktree remove` (never `--force`) and closes the lane. The branch is kept. A dirty or unpushed worktree is never removed. A no is remembered (`cleanup.sh reopen` takes it back).

## What the orchestrator may do alone

Start agents and gates, retry within a pattern's limit, commit, push the lane branch, open a **draft** pull request. It asks before marking a pull request ready, posting anywhere, or touching anything outside the lane. It never merges unless auto-merge is on for the lane (then only through `merge.sh`), and never approves, force-pushes or deletes a branch.

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

It binds `prefix+alt+g` to the `plugin_action` `herdr-graph-engineering.graph.toggle`. Running it again changes nothing when the toggle is already bound (to any key); it refuses when `prefix+alt+g` is taken by something else. Alt chords depend on your terminal (it must send Alt as Meta). The panel itself takes no hotkeys: it is driven by clicks, and the arrow keys only move a selection a click made.

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

- The orchestrator's own entry: what only you can do for it (a slash command such as `/reload-plugins` or `/compact`, a restart, a decision about the session) is recorded with `session.sh add --list needs --text ... [--prompt ...]` and shown at the top of NEEDS YOU:

  ```text
   NEEDS YOU (1)
   ● orchestrator                                      [done]
     Reload the plugins so the new version runs
     ▶ /reload-plugins
  ```

  A click on a `▶` line clears the orchestrator's input box and types that prompt there, **without Enter**: you press it. It types only into the session's recorded orchestrator pane, while the agent there is idle or done; otherwise the footer says `not typed:` and why. The entry leaves when the orchestrator removes it (`session.sh del --list needs --id N`), or with `[done]` (it asks first). The box is cleared with Ctrl+E and Ctrl+U only, repeated for further lines; never Ctrl+C or Esc, which can exit a client or interrupt a turn.

  | Client | Clearing | Check before typing |
  | --- | --- | --- |
  | Claude Code | Ctrl+E, Ctrl+U ([documented](https://code.claude.com/docs/en/interactive-mode): repeat to clear across lines) | the box must show as empty, else nothing is typed |
  | Codex | Ctrl+E, Ctrl+U (its default keymap) | the same |
  | OpenCode | Ctrl+E, Ctrl+U ([documented](https://opencode.ai/docs/keybinds/)), 20 pairs | none: its box cannot be recognised, so the footer says to check it before Enter |

  Not run against the real clients: the tests use the stub herdr. Text below the cursor's line in a multi-line draft is not cleared: Claude Code and Codex then get nothing typed.
- `/herdr-graph-engineering:display` opens or closes it. Without the Herdr plugin, `display` prints the same picture as text.
- Refresh: automatic, every 5s by default (`refresh=10s` in `$(herdr plugin config-dir herdr-graph-engineering.graph)/config` changes the start); `[◷ 5s]` cycles 5s, 10s, 15s, 30s, 1m, 5m; `[↻]` refreshes now. No title of its own (Herdr's pane border shows "Graph"), one column of padding each side; a thin divider and the grey footer sit on the pane's bottom rows, the footer saying when it last read and ending with the two buttons. The size is read from the terminal on every draw and a resize redraws at once.
- Layout: each lane starts with its fold chevron (▾ unfolded, ▸ folded); its chain, question, references, last line and pull requests hang under it on ├ and └, and long lines wrap inside that.
- Pull requests: each lane lists the pull requests of its branch, in every state, and every GitHub pull request it mentions (idea, question, references, history), so a review lane lists the pull request it reviews. Coloured by state: draft grey, open blue, approved green, changes requested amber, merged purple, closed red. Click one to open it in the browser. `scripts/prs.sh fetch` asks `gh` and caches the answer next to the lane files; the panel starts it in the background at most once a minute and draws from the cache, so a render never waits on the network. Without `gh` the list stays empty.
- Colour: plain ANSI 24-bit, the same in the panel and its popups: section headers bold red / amber / green / grey (CLOSED), `[confirm]` red (green for `[restore]`), lane names bold, patterns, references, `last:` lines and the footer grey, node marks coloured by state, the selected lane's first line on a subtle background. `NO_COLOR` turns it off (the selected lane is then marked `◂`).
- Click first: the panel acts on mouse clicks and the mouse wheel. Herdr passes mouse reports (the wheel too) to the panel because the panel asks for them, so it needs Herdr's `ui.mouse_capture`. Toggling the panel itself is a Herdr action (below), outside the pane.
- Arrows, after a click: once a click selected an element (a lane's first line, one of its lines, a pull request, a file reference, the CLOSED header, `… n more`), Up and Down move the selection one element at a time and scroll so it stays in sight; Left folds the selected element's lane (the selection goes to its first line) and Right unfolds it; on `… n more`, Right shows every closed lane. A selected lane's first line shows `◂` and the selection background; any other selected element starts with `›`. No other key does anything (none quits, presses or disarms a button), and before a click the arrows do nothing.
- Scrolling: the mouse wheel scrolls the lanes three lines a notch, the footer stays put. Below the last line there is blank room of 30% of the visible height, so the last lane need not sit on the bottom edge.
- A click on a lane selects it; a click on its chevron also folds or unfolds it; a double click on any of its lines (two clicks within 400 ms of the panel finishing the first) jumps to its agent, the blocked one first. A click on a pull request opens it in the browser; a click on any row of a file reference opens the file: a URL or an `.html` file in the browser, any other file in your editor (`$VISUAL`, else `$EDITOR`, else `open` on macOS or `xdg-open` on Linux). A terminal editor (vim, nvim, nano, micro, helix, `emacs -nw`, ...) cannot run inside the panel, so it opens in a new Herdr tab in the panel's workspace, which closes when the editor exits; set `GRAPH_EDITOR_TERMINAL=yes` or `no` when the guess is wrong. A GUI editor just starts.
- Buttons on a lane's first line, right-aligned: `[detail]` (the selected lane: its detail popup), `[answer]` (a lane that asks something: the answer popup; the answer goes to the orchestrator chat, which relays it), `[restore]` (the selected closed lane), `[x]` (a DONE or CLOSED lane). When they do not all fit the pane, they drop from the left (none in a pane too narrow for one).
- "Since last look" lists the lanes that moved section since your last click.
- CLOSED: the closed lanes of every repository the panel shows, newest first, folded (unfold one to see its pull requests in their final state); five, then `… n more` (click it to show all). A DONE or CLOSED lane ends with `[x]`, the CLOSED header with `[clear all]`, and left of it `[clear all reviews]` while a closed review lane exists. A review lane is one whose recorded pattern is `review` or `review-stack`; with no pattern or a custom one (a review stack started from `--pattern-file`), one on a `look/pr-<n>` branch. When the two buttons do not fit the pane's width, only `[clear all]` shows. `[x]`, `[restore]`, `[clear all reviews]` and `[clear all]` ask first: the first click turns the button into `[confirm]`, a second click on it acts, a click anywhere else puts it back. `[x]` on a DONE lane asks the lane's orchestrator to clean it up, which confirms with you before it removes the worktree; the panel removes nothing itself. `[x]` on a CLOSED lane first removes its worktree (`cleanup.sh remove`; while it cannot go, the entry stays and the panel says why). Then it, `[clear all reviews]` (closed review lanes only) and `[clear all]` (every closed lane) run `lane.sh clear`; the two bulk buttons remove no worktree. `lane.sh clear` moves the lane file from `closed/` to `closed/cleared/` (kept, no longer shown). `[restore]` (on the selected closed lane; its `[confirm]` is green) runs `lane.sh restore`, which moves the lane file back to the open lanes with its last status (a done lane comes back DONE) and records it in the lane's history; it refuses when an open lane has that name. Restoring brings back the record only: no worktree, branch or agent is recreated. A CLOSED lane lists its open done criteria (`open: ...`, also while folded), and a lane that closed by itself shows its `resume:` commands. A closed lane's pull requests are fetched until they are merged or closed.
- Actions to bind in your Herdr config (`[[keys.command]] type = "plugin_action"`): `herdr-graph-engineering.graph.toggle` (`install-keys.sh` binds it to PREFIX then Alt+G), `.refresh`, `.next-needs-me`.
- Toggle finds the panel by the pane it opened (kept in the plugin state folder, `$HERDR_PLUGIN_STATE_DIR`), as well as by its terminal title, so a panel that is still starting or lost its title is closed rather than doubled; a panel closed by hand is forgotten and the next toggle opens a new one. Toggles run one at a time, so two quick presses never open two panels in a tab. When the panel does not open, Herdr shows a notification.
- Ctrl-click a `.md` report path or a GitHub pull request URL to open it in a popup.
- After a Herdr restart it reopens next to the orchestrator and rewrites the sidebar tokens; a lane whose worktree you remove by hand is closed.
- It only reads, except a click on an orchestrator prompt line (types in the orchestrator's input box), its `[done]` (`session.sh del`), `[x]` on a closed lane (`cleanup.sh remove`, then `lane.sh clear`), `[clear all reviews]` and `[clear all]` (`lane.sh clear`), and `[restore]`, which goes through `lane.sh restore`. Lane files are still written only by `lane.sh`, answers still go through the orchestrator, and the only thing it stores is the pane id of the panel it opened.
- It never filters Herdr's sidebar (older versions did, with `f`, `n` and `F`); at start it clears a filter such a version may have left, through `nc -U` when `nc` is there. `.refresh` reaches open panels as the private sequence `ESC [ 99 ~`, which no key sends.

## Feedback loop

Off by default. `/herdr-graph-engineering:feedback-loop` turns it on or off for one orchestrator session (it asks with the client's question tool where there is one, in plain text otherwise), and the orchestrator asks the same once at its start. The choice is stored in the session file (`session.sh set --key feedback --value on|off`), so it survives a compaction; the resume block shows it as `FEEDBACK LOOP: on|off`.

When it is on:

1. **Before a lane is cleaned up**, `cleanup.sh check` prints `FEEDBACK <lane>` and `cleanup.sh run` refuses (`FEEDBACK DUE`) until the orchestrator has asked the lane's still-live agents how the whole flow (pattern, roles, briefs, gates, reviews, panel, scripts, the orchestrator's behaviour) could have been better, and written its own note. Both are also asked which guidance helped or prevented a mistake. `feedback.sh add` keeps these raw notes in `${XDG_STATE_HOME:-~/.local/state}/herdr-graph/sessions/feedback/<session>.yaml`, outside every repository.
2. **Notes become lessons.** The orchestrator writes general lessons from the notes with `feedback.sh lesson`, which stores one only when the sanitiser finds no task detail in it. Each lesson names the notes that support it (`--from-note`), and the script records them with their lanes; `feedback.sh lessons --support` shows them to you when a lane is offered, and no brief or repository gets them.
3. **Lessons become pull requests.** Every few lessons, at the end of a session, or when you ask, the orchestrator offers an improvement lane in the plugin's own repository. Its brief is the open lessons (`feedback.sh lessons`) and nothing else; it changes only the plugin's instructions, skills, roles, patterns, references and scripts. Its commit messages and pull request body must pass `feedback.sh sanitize` before the pull request opens, and you merge it as any other. While it is open its lessons wait (`feedback.sh proposed`); they count as used only after the pull request merged (`feedback.sh used --ref`, which asks `gh`), and a pull request closed unmerged reopens them with the reason (`feedback.sh reopen`). Lessons about the repository the lanes worked in go to that repository's documentation instead (below).

### Lessons about the repository

The loop has a second target besides the plugin: the documentation of the repository a lane worked in. Before cleanup, the agents and the orchestrator are also asked how that repository's `AGENTS.md`, `CLAUDE.md`, READMEs and docs could have helped more: guidance that was missing or wrong, rules agents kept tripping over, context that was hard to find, places where agents read too much or too little (context to trim, split or point to), commands that did not work as documented. These notes and lessons carry `--target repo --repo R` and are kept apart from the plugin's: `feedback.sh lessons` lists the plugin's, `feedback.sh lessons --target repo --repo R` that repository's, and each improvement lane gets only its own.

A repository's improvement lane runs in that repository, follows its own rules for branches, commits, checks and pull requests, and edits only its documentation (`AGENTS.md`, `CLAUDE.md`, READMEs, docs), never code, configuration or tests. The bar is higher: a repository lesson must be a general improvement that helps other tasks there ("the agent instructions should say how to run a single test and where its output goes"), never the task, ticket, pull request, branch, service-specific bug or data that produced it. `feedback.sh lesson --target repo` checks it with `--strict`, which also refuses identifiers (`snake_case` words, words with digits) and any inline code; the pull request body and commits pass `feedback.sh sanitize --strict`, and the orchestrator reads the diff.

### Keeping what the skills know

An instruction that is improved again and again can lose the specific knowledge that made it useful, one reasonable edit at a time. So the loop adds and extends, and a removal is deliberate, visible and approved:

- **The brief** of every improvement lane asks for the smallest targeted edit: no rewrite, merge, shortening or move of existing instruction text, and a question before any removal or weakening. A note that someone read something and did not need it never becomes a deletion by itself.
- **The preservation check**, `guard.sh check --repo <lane worktree> --base origin/<main> [--target repo] [--allow <file>]`, compares the instruction text of the branch with its merge base. For the plugin that is everything under `skills/`, `roles/`, `patterns/` and `references/`, plus every line of the existing tests and of the check itself; for a repository, `AGENTS.md`, `CLAUDE.md`, READMEs and the text files under `docs/`. It splits Markdown into sentences, headings, table rows and code lines (reflowing, list markers and table alignment change nothing), reports each one `REMOVED`, `CHANGED` or `MOVED` (another file, place or section; into a comment or code block counts as changed), and exits 3 until each is in the allow file as `<id> <reason>`. Pure additions pass. It needs no model, and it does not guess which sentences matter.
- **Out of the lane's reach.** The orchestrator runs its installed copy, with an allow file it keeps outside every checkout. The script refuses to run from inside the checkout it judges, or with an allow file there. This is a process barrier, not a security one: an agent running as the same user can write any file, and an installed copy can be older than the repository's.
- **Your yes.** You see each removal or weakening as old → new with its reason, and nothing is allowed without your yes. An id covers the old and the new text, so a later change needs a new one.
- **A second reader.** The `improve` pattern ends with a reviewer, of another agent kind when one is installed, whose brief is to check that existing expertise is preserved.

#### What the preservation check cannot see

- a new sentence that cancels, narrows or adds an exception to an old one: the old one is still there. The preservation review and your reading of the diff cover this;
- what a script does: it reads instruction text and the lines of tests, not behaviour;
- whether an edit makes anything better: nothing here runs the instructions on a task. The loop limits loss; it does not measure gain;
- files outside the paths above, and uncommitted changes.

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
- **Session facts** go in the session file, `${XDG_STATE_HOME:-~/.local/state}/herdr-graph/sessions/<name>.yaml`, written only by `session.sh`: the orchestrator's pane and scratch folder, your standing answers that have no file of their own (such as the worktree approval), queued lanes with their prepared brief, renames, notes and scratch files. One file per orchestrator and per user, because lanes span repositories. Text that looks like a token, key or password is refused.
- **`resume.sh`** prints all of it in one block: every open lane of every repository with lanes (nodes, agents live or gone, what a finished agent printed as its RESULT line (it runs `drift.sh --quiet` first), open question, pull requests, done checks, notes) with its next action, then the queue, the standing answers, and the standing kind and dialog choices that `kind.sh --remember` and the orchestrator keep in `<scratch>/graph-kinds` and `<scratch>/graph-dialogs`, renames, notes and files. The orchestrate skill runs it first after a compaction or in a new session, then re-starts `herdr:listen` only where the user asked to watch an agent.

`start.sh` is the orchestrator's first command, so the session file exists from the start; it also holds AFK, auto-merge and the recorded decisions, and `resume.sh` prints them with the open events.

**Claude Code and Codex** do this by themselves through the plugin's hooks (`hooks/hooks.json`; Codex once you trusted them): `PreCompact` writes a fresh block to `<session folder>/<name>.resume.md`, and `SessionStart` with the `compact` matcher puts the block back into the chat. Both do nothing outside the orchestrator's pane (the session whose `pane` is `$HERDR_PANE_ID`) and never fail the chat. In a pane whose agent is named `graph` with no session file, the block still comes back and says why it has no session. To compact by hand, give the summary a focus:

```text
/compact Keep: that I am the graph orchestrator (herdr-graph-engineering:orchestrate), my session name, and every user decision not yet written with lane.sh or session.sh. Lane and session state is in the files: after compacting, run resume.sh and follow it.
```

**OpenCode** does it through `opencode/herdr-graph.js`: `experimental.session.compacting` writes the snapshot, and after `session.compacted` the block goes back into the chat as a message that starts no turn. Where no hook or plugin runs, after a compaction or in a new session run `bash <plugin>/scripts/resume.sh` (or start the orchestrate skill again, which runs it first).

### Compacting at 40%

The orchestrator compacts by itself at 40% of its context: early and often, so the chat stays fast and the files carry the state. A plugin cannot set this (Claude Code reads it only from its environment or a settings file's `env`, and plugins ship neither), so `autocompact.sh` prints how and checks it, and writes only with `--write`:

| Client | Setting | Scope it to the orchestrator |
| --- | --- | --- |
| Claude Code | `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=40` (documented: the percentage of the auto-compact window at which auto-compaction triggers; it only lowers the threshold) | start only the orchestrator with it, or `autocompact.sh --write` puts it in `<folder>/.claude/settings.local.json` of the folder the orchestrator starts in (backup first; the home folder, which would be the global settings, is refused) |
| Codex | `model_auto_compact_token_limit` (a token count: 40% of the model's window, `--window`) | `codex -c model_auto_compact_token_limit=N` for the orchestrator only |
| OpenCode | `compaction.reserved` (a token count kept free: 60% of the window, `--window`; OpenCode 1.19.4 has no share setting and uses it only for a model that declares an input limit) | the `opencode.json` of the folder the orchestrator starts in |

The orchestrate skill runs `autocompact.sh check` at the start and offers the user the step once when it is off. Lane agents keep the default. In Claude Code the `PreCompact` hook has no matcher, so it runs on an automatic compaction as on `/compact`, and `SessionStart` with `compact` brings the block back either way.

## Tests

```bash
bash plugins/herdr-graph-engineering/tests/run-tests.sh
```

Hermetic: throwaway repositories and a stub `herdr`; no live session.

## Next

## Measuring

Run it on 10 to 20 real ideas, then `measure.sh` (or ask the orchestrator "how did the lanes go"): per lane the outcome, minutes, retries, questions to you and failures, and totals per pattern. Judge by the end state: did the lanes finish, how often were you asked, did retries run out. Remove a part (a node, a pattern, a check) that does not earn its place.
