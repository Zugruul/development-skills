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

- The `herdr` binary on `PATH`, and the agent running inside a Herdr pane (`HERDR_ENV=1`). Every skill checks this first and stops outside Herdr.
- `python3` (3.9+, standard library only) and `git`.

## Skills

| Skill | Purpose |
|---|---|
| `worktree` | Start a Herdr worktree: read-only plan, user approval, explicit `--cwd/--branch/--base/--path`, then optionally agents on it, each with a first prompt |
| `agent` | Start an agent in an existing pane (retrying while the pane is busy), wait until it is idle, send its first prompt |
| `prompt` | Send a follow-up prompt, or relay the user's answer to a blocked agent; never submits the same text twice |
| `listen` | Report what agents are doing, wait until one blocks, finishes or disappears, and surface a blocked agent's question to the user, asking which agent or tab when unclear |
| `orchestrate` | Take the orchestrator role, name the agent, load the skills above and the orchestration rules |
| `status` | Read-only roster of live agents and the repository's worktrees |

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

## `scripts/herdr_ctl.py`

```text
check                                  inside Herdr? prints version, workspace, tab, pane, own name
name NAME                              valid and unused agent name? (exit 6 when not)
worktree-plan --branch B [--base REF] [--path P] [--label T] [--cwd DIR]
                                       read-only checks, then the exact `herdr worktree create` line
start --name N --kind K --pane ID [--timeout S] [-- AGENT ARGS]
                                       agent start with retry on a busy pane, then wait for idle
prompt TARGET (--text T | --file F) [--while-working] [--confirm S]
                                       one guarded submission
roster [--workspace ID] [--repo DIR] [--json]
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
