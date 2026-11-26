# herdr-simple-orchestrate (deprecated)

The old way of orchestrating coding agents in [Herdr](https://herdr.dev): one agent takes the orchestrator role, starts other agents in worktrees, listens to them and relays their questions; and an orchestrated code review of a group of related pull requests.

These skills used to live in the [`herdr`](../herdr/README.md) plugin. They moved here so `herdr` only teaches how to use Herdr. The plugin is **deprecated**: it is kept, unchanged in behaviour, so existing setups keep working. It is not developed further.

## Install

```bash
claude plugin marketplace add Zugruul/development-skills
claude plugin install herdr-simple-orchestrate@development-skills   # installs herdr too
```

## Requirements

- The `herdr` plugin (its skills `herdr:worktree`, `herdr:agent`, `herdr:prompt`, `herdr:listen`, `herdr:status` do every Herdr step).
- `bash`, `jq` and `git`; the `herdr` binary, and the agent running inside a Herdr pane.
- `orchestrate-code-reviews` also needs `gh` for GitHub.

## Skills

| Skill | Purpose |
|---|---|
| `orchestrate` | Take the orchestrator role, name the agent, load the herdr skills and the orchestration rules. Its section 4 is the on-demand report (`NEEDS YOU`, `WORKING`, `DONE`) for the agents it follows. |
| `orchestrate-code-reviews` | Orchestrate a code review of related pull requests: one reviewer agent per open pull request in its worktree plus a cross-PR checker, drafts only, then one agent per pull request posts the replies and a single `COMMENT` review; the orchestrator verifies what was posted, then writes a summary and puts it into the body of that review. Never approves, requests changes, merges or pushes. |

## References

- `references/report.md`: the orchestrator report layout.
- `references/review-brief.md`, `references/review-summary.md`: the reviewer brief and the summary format of `orchestrate-code-reviews`.

## Scripts

This plugin carries the scripts its skills need, in bash with `jq`, and nothing else. It never calls into another plugin's folder.

```text
check.sh                                   inside Herdr? prints version, workspace, tab, pane, own name
name.sh NAME                               valid and unused agent name? (exit 6 when not)
label.sh TEXT...                           the hyphen-separated, no-space form of a workspace label
roster.sh [--workspace ID] [--repo DIR] [--json]
mine.sh [--cwd DIR] [AGENT ...]            the lists after a report: other agents, open worktrees
landed.sh [--cwd DIR] [--branch B] [--target B] [--remote R]
                                           is the branch's work on the main branch (same commits, or the
                                           same content after a squash or cherry-pick); prints the report row
```

Exit codes: `0` ok, `1` herdr or git error, `2` usage or not inside Herdr, `6` a check failed.

## Tests

```bash
bash plugins/herdr-simple-orchestrate/tests/run-tests.sh
```

Hermetic: a stub `herdr` written in bash stands in for the real binary.
