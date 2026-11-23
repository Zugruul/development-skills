# herdr

Skills that teach a coding agent to use [Herdr](https://herdr.dev), the terminal workspace manager for AI coding agents: start worktrees and agents, prompt them without duplicates, listen to their work, and act as an orchestrator.

The plugin is **standalone**. It knows Herdr and nothing else: no project workflow, no board, no other plugin. Integrations with the other development skills live in [`herdr-development-skills`](../herdr-development-skills/README.md), which builds on these skills.

It is also thin. Skills call the `herdr` CLI directly; the installed binary stays the authority for syntax (`herdr --help`, `herdr agent`, `herdr --skill`). One helper, `scripts/herdr_ctl.py`, covers only the sequences that need a wait, a retry or a safety check.

## Install

```bash
claude plugin marketplace add Zugruul/development-skills
claude plugin install herdr@development-skills
```

## Requirements

- The `herdr` binary on `PATH`, and the agent running inside a Herdr pane. Claude and other hosts use Herdr's injected `HERDR_ENV=1` caller context. Codex does not currently inherit that variable, so the helper accepts Codex only when `CODEX_SESSION_ID` is set and Herdr reports one live Codex agent whose `cwd` and `foreground_cwd` both exactly match the current checkout. A reachable server or an ordinary shell never passes this fallback. Every skill checks this first and stops outside Herdr.
- `python3` (3.9+, standard library only) and `git`.

## Skills

| Skill | Purpose |
|---|---|
| `worktree` | Start a Herdr worktree: read-only plan, user approval, explicit `--cwd/--branch/--base/--path`, then optionally agents on it, each with a first prompt |
| `agent` | Start an agent in an existing pane (retrying while the pane is busy), wait until it is idle, send its first prompt |
| `prompt` | Send a follow-up prompt, or relay the user's answer to a blocked agent; never submits the same text twice |
| `listen` | Report what agents are doing, wait until one blocks, finishes or disappears, and surface a blocked agent's question to the user, asking which agent or tab when unclear |
| `orchestrate` | Take the orchestrator role, name the agent, load the skills above and the orchestration rules |
| `status` | The on-demand status report, read-only: the orchestrator report for an orchestrator's own agents, then a short list of the other live agents and one of the repository's open worktrees; the same two lists, for all live agents, for any other agent |
| `orchestrate-code-reviews` | Take the orchestrator role for a code review of a group of related pull requests (stacked, or across repositories): map the group, one reviewer agent per open pull request in its worktree plus a cross-PR checker, drafts only, then one agent per pull request posts the replies and a single `COMMENT` review; the orchestrator verifies what was posted and writes a summary |

## What the skills handle for you

These come from driving Herdr by hand; each is covered by a test.

- **A new pane is not ready at once.** A pane just made by `herdr worktree create` is still starting its shell, and `herdr agent start` fails with `agent_pane_busy`. `herdr_ctl.py start` retries until Herdr accepts the pane.
- **Start and prompt are separate steps.** Start, wait until idle, then prompt.
- **A full-screen agent's transcript is on the visible screen.** `herdr agent read --source recent-unwrapped` misses it; `peek` and `listen` read `--source visible`.
- **Nothing notifies an orchestrator.** Listening is `herdr agent wait` or polling. `herdr_ctl.py listen` polls several agents at once.
- **A timeout does not prove a prompt was not delivered.** `herdr_ctl.py prompt` sends at most once and answers `PROMPT UNCONFIRMED` instead of retrying; the skills say to read the screen before anything else.
- **Worktrees are explicit and approved.** `--cwd`, `--branch`, `--base` and `--path` are always passed; the path follows the repository's own location rule when it has one; the user is asked before creation unless they already asked for the worktree. `--trust-repository` is never added.
- **Agent names** must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents; checked before `agent start`.
- **Blocked agents wait on a human.** An approval or question is shown to the user and answered only as they decide.

## Orchestrator report

`references/report.md` is the one layout an orchestrator uses to report the state of its agents; `orchestrate`, `listen`, `status` and `worktree` point to it. It is Markdown grouped by state, never inside a code fence: a first line with what changed since the last report, then `NEEDS YOU`, `WORKING` and `DONE` with their counts and one list item per agent. An agent's pull requests are a `prs:` block with one line each, in the order opened: number, state (`draft`, `open`, `merged`, `closed`) and the full bare URL, aligned in columns, with no Markdown link syntax. Work that reached the main branch without a pull request is one more row of that block, `🟣 direct  merged  main @ <commit>` (or `⚪ direct  local` while it is only on the local main branch); the orchestrator gets the row from `herdr_ctl.py landed`, which reads git and also recognises a squash or cherry-pick with a different hash, never from what the agent says. The URL is bare so a terminal can detect it and it can be copied; whether a click opens it depends on the terminal. Observed in Claude Code inside Herdr 0.9.5 with default configuration: a click does not open it, because Herdr's default `ui.mouse_capture = true` takes the mouse clicks; with mouse capture off, and on other hosts, it is unverified. The plugin adds no workaround.

Color comes from a small fixed set of emoji, always next to the word they stand for: `🔴 NEEDS YOU`, `🟡 WORKING`, `🟢 DONE` on the section lines; `⚪ draft`, `🔵 open`, `🟣 merged`, `🔴 closed` at the start of a pull request line; `⚠` at the start of what is only claimed; and `⚫` on the `idle:`, `state: unknown` or `gone:` line of an agent placed by those rules. No other emoji appears in a report. A blocked agent's question is quoted exactly; a done agent lists what the orchestrator verified apart from what the agent only claims. The file also fixes where `idle`, `unknown` and gone agents go, so no agent is missing and none that Herdr cannot classify is shown as done.

It applies only to an agent that has taken the orchestrator role. A plain `status` or `listen` call keeps its own output.

`/herdr:status` is the on-demand command for it. The role and the list of agents an orchestrator started are known only from the session's own conversation; Herdr does not record them. So when an agent cannot tell (for example after its context was summarised), `status` falls back to the plain lists, says so, and asks which agents to follow rather than guessing. After the report (or alone, for an agent that is not orchestrating) `status` shows two short lists printed by `herdr_ctl.py overview`: the live agents (workspace id, the workspace label as Herdr's sidebar shows it, kind, state, and the agent's name when it has one) and the repository's worktrees that have an open Herdr workspace (workspace label, branch), with the open-of-total count in the heading and no paths. Labels are printed in full. Their columns are aligned with spaces, so the skill pastes them unchanged inside a code block; the orchestrator report itself stays unfenced. The `Since last report` line compares with the most recent report in the conversation and says `unknown` when that report is no longer in context. Other plugins that make an agent the orchestrator may add their own lines inside an agent's entry.

## Code review of related pull requests

`/herdr:orchestrate-code-reviews <pull request URLs and optional notes>` builds on `orchestrate` and the other skills; it repeats none of their rules. It is the one skill here that also needs a command-line client for the hosting service (`gh` for GitHub). It knows no particular repository: per repository under review the orchestrator discovers the rule files that exist (agent instructions, security rules, testing and contribution documents) and passes their paths into every brief and every fix prompt.

- Asks for the URLs when the list is empty or holds placeholders, and for the reviewer agent kind with a stated default, before anything else.
- Labels each workspace it creates `pr-<number>-<owner>-<short description>` and names each reviewer `review-<number>-<short description>`, so the sidebar entry shows which pull request it is, who owns it and what it is about.
- A merged pull request is reference behaviour only: no worktree, read from the freshly fetched default branch, never commented on; a fix that belongs there is a proposed follow-up in the report.
- Reviewers only draft, to files in the orchestrator's scratch directory. The orchestrator merges the drafts (a finding two agents found is posted once) and one agent per pull request posts, after re-checking what it posts on another agent's behalf.
- Never marks ready, approves, requests changes, merges or pushes. After posting, the orchestrator verifies the reviews, the pull request's state and the worktree through the hosting service before it reports links.
- Closes down after itself: once a pull request's comments are posted and verified, its reviewer writes a result file back to the orchestrator, and the worktree, workspace and tabs this review created are removed (never forced, never anything reused or unverified). Only the files in the orchestrator's scratch directory remain.
- `references/review-brief.md` holds the reviewer brief, the proof standard, the rules for shared checkouts and the draft and comment formats. `references/review-summary.md` holds the format of the final summary, which is written to a file and posted as a pull request comment only when the user asks.

## `scripts/herdr_ctl.py`

```text
check                                  inside Herdr? prints version, workspace, tab, pane, own name
name NAME                              valid and unused agent name? (exit 6 when not)
label TEXT...                          the hyphen-separated, no-space form of a workspace label
worktree-plan --branch B [--base REF] [--path P] [--label T] [--cwd DIR]
                                       read-only checks, then the exact `herdr worktree create` line;
                                       refuses a label with spaces, always passes --label
start --name N --kind K --pane ID [--timeout S] [-- AGENT ARGS]
                                       agent start with retry on a busy pane, then wait for idle
prompt TARGET (--text T | --file F) [--while-working] [--confirm S]
                                       one guarded submission
roster [--workspace ID] [--repo DIR] [--json]
overview [--cwd DIR] [--mine NAME ...]  the status skill's two lists: live agents, open worktrees
landed [--cwd DIR] [--branch B] [--target B] [--remote R]
                                       is the branch's work on the main branch (same commits, or the
                                       same content after a squash or cherry-pick); prints the report row
peek TARGET [--lines N] [--history N]  state plus the visible screen
listen TARGET... [--timeout S] [--only-blocked]
```

Exit codes: `0` ok, `1` herdr or git error, `2` usage or not inside Herdr, `3` agent started but blocked, `4` prompt refused, `5` prompt sent but unconfirmed, `6` a pre-creation check failed.

## Proposed skills (not implemented)

| Skill | Why it would help |
|---|---|
| `cleanup` | Remove the worktrees and close the workspaces an orchestrator created once their work has landed; destructive, so it needs its own confirmation and "did it merge?" checks |
| `run` | Run an ordinary command (tests, a dev server) in a sibling pane and wait for a line of output, for work that needs a terminal but not an agent |
| `machines` | Orchestrate agents on saved SSH machines with `herdr --machine`, where ids and names are scoped per server |
| `broadcast` | Send one announcement to several agents ("main moved, rebase before pushing") with per-agent delivery results |
| `handoff` | Collect every agent's last state and unfinished work into one note when the orchestrator stops |
| `layout` | Arrange or zoom panes and tabs for a review session; cosmetic, and focus changes can disturb the user |

## Tests

```bash
bash plugins/herdr/tests/run-tests.sh
```

Hermetic: a stub `herdr` (`tests/fixtures/stub-herdr/herdr`) stands in for the real binary, so the suite needs no Herdr install and never touches a live session. It also checks that no knowledge of the specialized plugins leaks into this one.
