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
| asks why, how, where, what, whether; asks to investigate, find out, explain, compare, check | `investigate` |
| names a pull request to review | not available yet: say so and offer `investigate` on the pull request instead |
| matches the `when:` of a repository or user pattern better than the above | that pattern |
| fits none, or fits two | ask the user, naming the candidates |

Pick the **smallest** pattern that does the job. One agent is the default; more agents only when the pattern says so.

## 3. Lane name

A lowercase slug of at most 24 characters, saying what the lane is about: `task-rate-limit`, `why-sync-slow`. Unique among the repository's open lanes (`lane.sh list`).

## 4. Gate command (patterns with a `{gate}` node)

Read the repository's own instructions (`AGENTS.md`, `CLAUDE.md`, contributing notes) and its manifest (`package.json` scripts, `Makefile`, `pyproject.toml`, ...). Propose the narrowest command that proves the change: the package's own tests rather than the whole monorepo. Show it in the lane approval; it runs only after the user approved it. A command proposed by a pattern that came from a cloned repository is shown the same way: nothing runs that the user has not seen.

## 5. Branch and worktree

- Changing patterns (`solo`): branch `feat/<lane>`, base a freshly fetched `origin/<main branch>`.
- Read-only patterns (`investigate`): branch `look/<lane>` from the same base. It exists so the checkout is the lane's alone.
- Path: the repository's own worktree location rule when it has one, otherwise Herdr's default.
