# herdr

Skills that teach a coding agent to use [Herdr](https://herdr.dev), the terminal workspace manager for AI coding agents: start worktrees and agents, prompt them without duplicates, listen to their work, and see what is running.

The plugin only teaches Herdr. It has no workflow of its own and knows no other plugin. Workflows that coordinate several agents are built on top of it in separate plugins.

It is also thin. Skills call the `herdr` CLI directly, and the installed binary stays the authority for syntax (`herdr --help`, `herdr agent`, `herdr --skill`). There are four small bash scripts, each for something the CLI cannot do in one call.

## Install

```bash
claude plugin marketplace add Zugruul/development-skills
claude plugin install herdr@development-skills
```

## Requirements

- The `herdr` binary on `PATH`, and the agent running inside a Herdr pane. Claude and other hosts use Herdr's injected `HERDR_ENV=1` caller context. Codex does not currently inherit that variable, so `check.sh` accepts Codex only when `CODEX_SESSION_ID` is set and Herdr reports one live Codex agent whose `cwd` and `foreground_cwd` both exactly match the current checkout. A reachable server or an ordinary shell never passes this fallback. Every skill checks this first and stops outside Herdr.
- `bash` (3.2 or later, so the macOS default works; WSL on Windows), `jq` and `git`. No Python.

## Skills

| Skill | Purpose |
|---|---|
| `worktree` | Start a Herdr worktree: read-only checks, user approval, explicit `--cwd/--branch/--base/--path/--label`, then optionally agents on it, each with a first prompt |
| `agent` | Start an agent in an existing pane (retrying while the pane is busy), wait until it is idle, send its first prompt |
| `prompt` | Send a follow-up prompt with `herdr agent prompt --wait`, or relay the user's answer to a blocked agent; never submits the same text twice |
| `listen` | Report what agents are doing, wait until one blocks, finishes or disappears, and surface a blocked agent's question to the user, asking which agent or tab when unclear |
| `status` | Read-only: the live agents (workspace, label, kind, state, name) and the repository's worktrees that are open in Herdr, as two aligned lists |

## What the skills handle for you

These come from driving Herdr by hand; each is covered by a test.

- **A new pane is not ready at once.** A pane just made by `herdr worktree create` is still starting its shell, and `herdr agent start` fails with `agent_pane_busy`. `start.sh` retries until Herdr accepts the pane, then waits until the agent is idle.
- **Start and prompt are separate steps.** Start, wait until idle, then prompt.
- **A full-screen agent's transcript is on the visible screen.** `herdr agent read --source recent-unwrapped` misses it; the skills read `--source visible`.
- **Nothing notifies a listener.** One agent: `herdr agent wait`. Several at once: `listen.sh`, which returns at the first that blocks, finishes or disappears.
- **A timeout does not prove a prompt was not delivered.** `herdr agent prompt --wait` sends at most once; on a stall or timeout the skills read the screen before anything else and never resend blindly.
- **Worktrees are explicit and approved.** `--cwd`, `--branch`, `--base`, `--path` and `--label` are always passed; the path follows the target repository's own location rule when it has one, where the target is the git toplevel of the checkout being changed, so a rule from an enclosing repository never applies to a standalone clone nested inside it; `check-path.sh` refuses a path inside another repository's working tree; the user is asked before creation unless they already asked for the worktree. `--trust-repository` is never added.
- **Agent names** must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents; `start.sh` checks before `agent start`.
- **Blocked agents wait on a human.** An approval or question is shown to the user and answered only as they decide.

## Scripts

```text
check.sh                                inside Herdr? prints version, workspace, tab, pane, own name
start.sh --name N --kind K --pane ID [--timeout S] [-- AGENT ARGS]
                                        agent start with retry on a busy pane, then wait for idle
listen.sh TARGET... [--timeout S] [--lines N] [--only-blocked]
                                        the first of several agents to block, finish or disappear
check-path.sh --target CHECKOUT --path P [--target-rule]
                                        refuses a worktree path inside a repository other than the target
```

Exit codes: `0` ok, `1` herdr error or refused path, `2` usage or not inside Herdr, `3` agent started but blocked, `6` invalid or taken name.

## Tests

```bash
bash plugins/herdr/tests/run-tests.sh
```

Hermetic: a stub `herdr` in bash (`tests/fixtures/stub-herdr/herdr`) stands in for the real binary, so the suite needs no Herdr install and never touches a live session. It runs the `status` skill's jq lists exactly as written, and checks that the plugin stays pure: no Python, no orchestrator workflow, no knowledge of other plugins.
