# Orchestrator report

The one layout an orchestrator uses whenever it reports the state of its agents. The skills point here instead of describing a layout of their own.

## When it applies

- You have taken the orchestrator role, through the `orchestrate` skill or through another skill that makes you the orchestrator.
- You are reporting the state of the agents you follow: after an agent blocks, settles or disappears, when the user asks how things stand, and when you stop.

It does not apply to an agent that is not orchestrating. A plain `status` or `listen` call keeps that skill's own output. The `status` skill says how an agent tells which case it is in, and what it does when it cannot tell.

The report covers the agents you started or were asked to follow. Other agents on the Herdr server are not yours and are not listed.

## The format

The report is Markdown, written straight into your reply. **Never wrap the report in a code fence** and never indent the whole report as a code block. The block below is fenced only so this file can show the source; what you send is its content, unfenced.

```markdown
Since last report: claude-lane-1k5a5ew4cde working -> done

**🔴 NEEDS YOU (1)**

- **herdr-dev** · w2A · feat/herdr
  - branch + label rule
  - asks: "How should the new rule relate to branchPattern?" 1) ... 2) ... 3) ...

**🟡 WORKING (1)**

- **dev-rest-204** · w2B · fix/rest-service-healthcheck-204
  - rest healthcheck -> 204 (4m, writing Bruno)
  - prs:
      ⚪ #2788 draft   https://github.com/<owner>/<repo>/pull/2788

**🟢 DONE (1)**

- **claude-lane-1k5a5ew4cde** · w2D · feat/1k5a5ew4cde-image-input
  - image input for the decision API -> 2 commits
  - prs:
      ⚪ #2795 draft   https://github.com/<owner>/<repo>/pull/2795
      🔵 #2801 open    https://github.com/<owner>/<repo>/pull/2801
      🟣 #2807 merged  https://github.com/<owner>/<repo>/pull/2807
      🔴 #2811 closed  https://github.com/<owner>/<repo>/pull/2811
  - verified: PR state, 2 commits, diff
  - claimed: ⚠ 103 + 28 tests pass
```

## Rules

1. **Markdown, not a code block.** Bold section lines and nested lists only. No table, no code fence around the report, nothing that needs a wide pane. It must keep its shape in a narrow pane and on every host.
2. **First line: what changed.** `Since last report: <agent> <old state> -> <new state>`, one line per change. `Since last report: nothing changed` when nothing did. Leave the line out of your first report. The comparison is with your most recent report in this conversation, whether you sent it after an event or on demand through the `status` skill. If you sent one earlier but it is no longer in your context, write `Since last report: unknown (the earlier report is no longer in my context)` and do not reconstruct old states from memory.
3. **Three sections, always in this order:** `NEEDS YOU`, `WORKING`, `DONE`, each a bold line of its own that starts with its state dot and ends with its count in parentheses: `🔴 NEEDS YOU (n)`, `🟡 WORKING (n)`, `🟢 DONE (n)`. Leave out a section that has no agents. Never add a fourth section.
4. **Every agent you follow is in exactly one section,** as one list item with its lines nested under it. Check the counts against your list of agents before sending.
5. **Per agent, line 1** (the list item): its name in bold, its workspace id, its branch, separated by ` · `. An unnamed agent is shown by its pane id.
6. **Per agent, line 2** (first nested line): what it was asked to do, in a few words. Then:
   - a working agent: how long it has been on this turn and what it is on right now, in parentheses, from its screen;
   - a done agent: `->` and the result (commits, files). Pull requests go in the `prs:` block, not here.
7. **Pull requests: a `prs:` block**, in any section, for an agent that has opened any. The nested line is `prs:` alone; under it, indented four more spaces, comes one line per pull request in the order they were opened: the dot of its state, `#N`, the state in words, then the URL. The state is one of `draft`, `open`, `merged`, `closed`, with the dots `⚪ draft`, `🔵 open`, `🟣 merged`, `🔴 closed`. Pad the number and the state with spaces so the URLs start in the same column. The URL is written in full and bare, with no Markdown link syntax, no angle brackets and nothing after it, so a terminal can detect it and it can be copied. An agent with one pull request uses the same block. An agent with none has no `prs:` line. Use the URL exactly as the hosting service or the agent gave it; never guess an address, and when you have a number but no URL, write the number and state alone. Work that reached the main branch without a pull request is a `direct` row of this same block (see "Work merged without a pull request"), and an agent with only that row still has the block.
8. **A done agent then has two more lines:** `verified:` for what you checked yourself (the diff, the commits, a pull request's state, test output you read on its screen) and `claimed:` for what only the agent says. The content of `claimed:` starts with `⚠`; `verified:` has no marker. Leave a line out when it would be empty; never move a claim to `verified:` because it is probably true.
9. **A blocked agent's question is quoted exactly**, after `asks:`, with its options as its screen shows them. Do not summarise, reorder or pre-answer it.
10. **Other lines inside an entry** are allowed when the skill that made you the orchestrator defines them. They are nested lines like the rest, one fact per line, as `<word>: <value>`, placed after the `prs:` block and before `verified:`.

## Color

A reply cannot set text colors, so the report's color comes from a fixed, small set of emoji. These are the only emoji allowed anywhere in the report:

| Mark | Where | Meaning |
| --- | --- | --- |
| 🔴 | section line | NEEDS YOU |
| 🟡 | section line | WORKING |
| 🟢 | section line | DONE |
| ⚪ 🔵 🟣 🔴 | start of a pull request line | draft, open, merged, closed |
| ⚠ | start of the content of `claimed:` | not checked by the orchestrator |
| 🟣 ⚪ | start of a `direct` line | `merged`: on the remote's main branch; `local`: on the local main branch only, not pushed |
| ⚫ | start of an `idle:`, `state: unknown` or `gone:` line | an agent that is idle, unclassified by Herdr or gone (see the table below) |

- **Never color alone.** The word always stays next to its dot (`🔴 NEEDS YOU`, `⚪ #2795 draft`, `⚫ state: unknown`), so the report reads the same on a host or font without emoji.
- Green means DONE and nothing else: an open pull request is blue. Red appears twice, for NEEDS YOU and for a closed pull request; the word next to it says which.
- No other emoji, no per-agent dots, no decoration. Do not add a dot to an agent's first line or to `verified:`.

## Work merged without a pull request

An agent's work can reach the main branch with no pull request: pushed straight to it, or squashed or cherry-picked onto it by someone else. The report shows that as one more row of the `prs:` block, after the pull requests, with the word `direct` where the number would be and the target branch and commit where the URL would be:

```markdown
- **herdr-dev** · w2A · feat/herdr
  - relay rule + labels -> 2 commits
  - prs:
      ⚪ #2795   draft   https://github.com/<owner>/<repo>/pull/2795
      🟣 direct  merged  main @ 4e843cc
  - verified: commits on origin/main
```

An agent with no pull request has the block with the `direct` row alone. Pad `#N` to the width of `direct` so the columns stay aligned.

**Never write this row from what the agent says or from memory.** Get it from git, for the agent's checkout:

```bash
git -C <agent's checkout> fetch origin          # so the answer is about the remote as it is now
python3 "../scripts/herdr_ctl.py" landed --cwd <agent's checkout>    # path relative to this file
```

`landed` changes no ref and no file. It prints a `ROW` line to copy as is, or says there is none:

| `landed` prints | Meaning | Row |
| --- | --- | --- |
| `MERGED origin/main @ <commit> (same commits)` | the branch's own commits are on the remote's main branch | `🟣 direct  merged  main @ <commit>` |
| `MERGED origin/main @ <commit> (same content)` | the commits differ (a squash, a cherry-pick, a rebase) but merging the branch into the remote's main branch would change nothing; `<commit>` is the first commit on main where that became true | `🟣 direct  merged  main @ <commit>` |
| `LOCAL main @ <commit>` | the work is on the local main branch only | `⚪ direct  local   main @ <commit>` |
| `NOT MERGED` | neither | no row |
| `ON TARGET` | the agent works on the main branch itself and nothing is unpushed | no row from `landed`: take the commit from the agent and check it with the `git merge-base --is-ancestor` line `landed` prints; write the row only when that succeeds |

Rules:

- **`merged` means on the remote's main branch**, the same as a merged pull request. Work that is only on the local main branch is `⚪ direct  local`, never purple: nobody else has it yet.
- **States before that get no row.** Uncommitted or committed-but-unmerged work is what line 2 already says (`-> 2 commits`); `landed` notes uncommitted changes so you can say so there.
- **The main branch** is the remote's default branch; `--target <branch>` when the work was meant for another one. The name printed in the row is that branch.
- **A row from `landed` is verified.** Say so under `verified:` (for example `commits on origin/main`). If you could not fetch, the answer is as of the last fetch: say that too.
- **When `landed` says `NOT MERGED` but the agent says it landed**, there is no row; the agent's statement goes under `claimed:`. The same-content check gives up when merging would conflict, for example when main changed the same lines afterwards.
- **A branch with no commits of its own also reads as `same commits`.** Use the row only for an agent whose result includes commits.
- **A pull request that was merged is its own `🟣 #N merged` row.** Do not add a `direct` row for the same work.
- Run it again for each report: a `local` row becomes `merged` once the main branch is pushed.

## Opening a pull request: what is and is not guaranteed

The URL is written bare so that a terminal which detects URLs can open it and so that it can always be selected and copied. Whether a click opens it depends on the terminal and on Herdr, not on this plugin.

**Observed:** in Claude Code inside Herdr 0.9.5 with Herdr's default configuration, a click does not open the URL. Herdr's default `ui.mouse_capture = true` makes Herdr handle mouse clicks itself, so they do not reach the terminal. Whether it opens with mouse capture turned off is unverified, and so is every other host (Codex, OpenCode, others).

So:

- Do not tell the user the URLs are clickable. Under Herdr's defaults they are not.
- Do not change the user's Herdr configuration, and do not add a workaround of your own (opening URLs for them, Markdown links, shortened addresses, printing a URL a second time).
- If the user says a URL does not open on their host, say that the form is fixed here and where the limit lies; do not invent another format.

## Where each state goes

Herdr reports `working`, `blocked`, `done`, `idle` and `unknown`; an agent can also be gone. Look at an agent's screen before placing anything but `working`.

| State | Section | How it is shown |
| --- | --- | --- |
| `blocked` | NEEDS YOU | `asks:` with the exact question and options |
| `working` | WORKING | time on this turn and what it is on |
| `done` | DONE | result, then `verified:` / `claimed:` |
| `idle`, its screen shows it finished what it was asked | DONE | as `done` |
| `idle`, it stopped with a question or is waiting for a decision | NEEDS YOU | `asks:` with its question quoted exactly |
| `idle`, it was never given work, or you cannot tell why it stopped | NEEDS YOU | `⚫ idle: <what its screen shows>` |
| `unknown`, its screen shows a question or an approval | NEEDS YOU | `asks:` with the question, and `⚫ state: unknown` on its own line |
| `unknown`, its screen shows it is plainly mid-turn | WORKING | what it is on, and `⚫ state: unknown` on its own line |
| `unknown`, anything else | NEEDS YOU | `⚫ state: unknown - <what its screen shows>` |
| gone, and you had already reported it DONE | none | named once in the `Since last report` line (`done -> gone`), then dropped |
| gone, in any other case | NEEDS YOU | `⚫ gone: <its last known state and what it was on>`, until the user says what to do |

There is no fourth section for these agents: each goes into one of the three sections above, and the black dot `⚫` on its `idle:`, `state: unknown` or `gone:` line is what sets it apart from the agents that belong there by their own state. `⚫` is used for nothing else.

Two things follow from this and are never traded away:

- An agent Herdr cannot classify is never shown under DONE. `unknown` is not completion.
- No agent is silently dropped. One that disappeared before it was reported DONE stays under NEEDS YOU, with `verified:` for whatever its branch shows, until the user has seen it.

## After the report

The format covers the state of the agents and nothing else. Longer material follows it in normal prose: a finished agent's full outcome, findings, open decisions and the exact action each needs from the user.
