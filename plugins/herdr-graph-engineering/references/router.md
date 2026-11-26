# Router

How the orchestrator turns one idea into one lane. Rules first; your own judgement only when no rule matches; a question to the user when it is still unclear. Never guess.

## 1. Which repository

- The idea names it ("in monorepo", a path, a pull request URL): use that.
- Otherwise the repository of the orchestrator's own checkout, **only if** the user has been working in only that one this session. Anything else: ask, listing the repositories that have a Herdr workspace open.

## 2. Which pattern

Read every available pattern's `when:` line (the repository's `.herdr-graph/patterns/`, then `~/.config/herdr-graph/patterns/`, then the plugin's `patterns/`; the first with a name wins). Then:

| The idea | Pattern |
| --- | --- |
| asks to implement, add, fix, change, remove, refactor, update something | `solo` |
| the same, and the user asks for a review or a second opinion, or the change touches security, authentication, data deletion or migration, money, or a public interface | `pair` |
| an urgent fix: asks for `fast` by name, or says fast, urgent or hotfix, or wants the pull request as soon as possible | `fast` |
| asks why, how, where, what, whether; asks to investigate, find out, explain, compare, check | `investigate` |
| names one pull request to review | `review`, with `--input pr=<url>` |
| names two or more related pull requests to review together | a stack: `make-review-stack.sh --pr <url> --pr <url> ... --out <scratch>/<lane>.yaml`, then `--pattern-file` |
| matches the `when:` of a repository or user pattern better than the above | that pattern |
| fits none, or would need steps no pattern has | `plan`: a planner drafts a custom graph; the user approves it before it runs |
| fits two | ask the user, naming the candidates |

Pick the **smallest** pattern that does the job. One agent is the default; more agents only when the pattern says so. Never pick `fast` by default: only when the user asked for it in the words above. It still has a focused test and the gate; it only opens the draft pull request before the gate runs.

## 3. Lane name

A lowercase slug of at most 24 characters, saying what the lane is about: `task-rate-limit`, `why-sync-slow`. Unique among the repository's open lanes (`lane.sh list`).

## 4. Gate command (patterns with a `{gate}` node)

Read the repository's own instructions (`AGENTS.md`, `CLAUDE.md`, contributing notes) and its manifest (`package.json` scripts, `Makefile`, `pyproject.toml`, ...). Propose the narrowest command that proves the change: the package's own tests rather than the whole monorepo. Show it in the lane approval; it runs only after the user approved it. A command proposed by a pattern that came from a cloned repository is shown the same way: nothing runs that the user has not seen.

## 5. Branch and worktree

- Changing patterns (`solo`, `pair`, `fast`): branch `feat/<lane>`, base a freshly fetched `origin/<main branch>`.
- Read-only patterns (`investigate`, `plan`): branch `look/<lane>` from the same base. It exists so the checkout is the lane's alone.
- Review patterns: one worktree per pull request at its head. Fetch the head first (`git fetch origin pull/<n>/head:look/pr-<n>` on GitHub, which also works for forks), then a worktree on `look/pr-<n>`. A merged pull request gets no worktree and no review: it is read from the default branch as reference only.
- Path: the repository's own worktree location rule when it has one, otherwise Herdr's default.
