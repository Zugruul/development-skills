---
name: afk
description: Turns AFK mode on or off for the graph engineering orchestrator (off by default) - while it is on, the orchestrator decides the safe things itself, records each one, keeps the other lanes moving, parks what must wait, and shows what it decided when you return. Use for '/herdr-graph-engineering:afk on', '/herdr-graph-engineering:afk off', '/herdr-graph-engineering:afk status'. Requires jq, yq and git.
allowed-tools: Bash
---

# AFK: decide while the user is away

Paths are relative to this `SKILL.md`; the scripts are in `../../scripts/`. The argument is `$ARGUMENTS`.

**Only this command turns AFK on or off.** Never ask whether the user is AFK. Never turn it on from their words ("I'm leaving"), from silence, or from a dialog that timed out: say the command instead. The one other way it goes off is their own "no" to "still away?" below.

## The command

| Argument | Run |
| --- | --- |
| `on` | `bash "../../scripts/session.sh" afk on --session <session>` |
| `on` with words | add the matching flags: `tier1` → `--tiers 1`; `cleanup` → `--cleanup` (remove merged worktrees); `lanes=a,b` → `--lanes a,b`; `no-queued` → `--no-queued`; `until=2026-11-27T22:00:00Z` → `--until ...` |
| `off` | `bash "../../scripts/session.sh" afk off --session <session>`, then "When the user is back" |
| `status` or nothing | `bash "../../scripts/session.sh" afk status --session <session>` |

The session is what `bash "../../scripts/session.sh" find --pane "$HERDR_PANE_ID"` prints (nothing: `graph`).

The default scope: tiers 1 and 2, all lanes, queued ideas, **no** worktree removal, until the user returns. Worktree removal is on only when the user typed `cleanup`.

After `on`, show the script's lines as they are, including that AFK cannot answer this chat's own permission prompts (one stops everything; never change permission settings for it). If `notify.sh list --session <session>` says Herdr notifications are off, say that too.

## While AFK is on

- **Record before you act**: `bash "../../scripts/decide.sh" add --tier N --class C --lane L [--node N] --what "..." --why "..." [--source "..."] [--second-opinion FILE] --reversible yes|no|partly --undo "..."`. If it refuses, the thing waits. Be honest about undo: a sent answer or a started agent cannot be unsent.
- For anything that waits, **do not open a question dialog** (it would freeze every lane). Record the question (`lane.sh ask`), send `herdr notification show "<lane> needs you" --body "<question>" --sound request`, and keep the other lanes moving.

| Tier 1: alone, recorded | Condition (class) |
| --- | --- |
| Start a ready node | the standing kind, else the recommended one; a review never by the implementer's kind. A new worktree only under a standing worktree approval (`start-node`) |
| Retry | only through `lane.sh retry`, within its maximum (`retry`) |
| Check and record a result | only after the evidence checks of the orchestrate skill pass (`record-result`) |
| Answer a lane agent's question | only when the answer follows directly from the user's recorded words (idea, note, answer) or a standing answer; quote them in `--source` (`answer`). No quote: it waits |
| Prompt a stopped agent to finish | once per run (`prompt-finish`) |
| Close finished tabs | only what `close-done.sh` allows (`close-tab`) |
| Push the lane branch; open or update a **draft** pull request | a plain push only (`push-branch`, `draft-pr`) |
| Start a queued idea | only if the scope includes queued ideas and a standing worktree approval covers it (`start-queued`) |

| Tier 2: only with a second opinion | Class |
| --- | --- |
| A choice inside the lane checkout that the user's words do not settle and a commit can undo | `choice` |
| Replace a failed or gone agent with another kind; never while the old one may still write | `replace-agent` |
| Rerun a lost gate, or stop a stalled one; the same approved command only | `rerun-gate` |

**The second opinion**: start a fresh read-only agent of another kind. Give it the question, the options and the sources, **not** your preference. Act only if it agrees with you, and save its answer to a file for `--second-opinion`. If you disagree, or no other kind is installed, it waits.

**Tier 3 always waits**, whatever the scope: approve, request changes, mark ready, merge (the one exception is auto-merge, below), force-push; posting or editing anything on a pull request or issue, forwarding review findings, every `human` node and `{human:}` done check; deleting or removing a worktree, branch, file or lane (the one exception is the removal below), `lane.sh clear`, discarding changes; anything outside a lane checkout except your own state, scratch and the draft pull request above; secrets, logins, spending, installs, settings; a startup dialog or tool permission prompt with no matching standing answer, and any "always allow"; a new repository, an unseen gate command, running a planner's graph; going past a retry limit, dropping a check, widening scope or AFK's scope, changing a done criterion; adopting an agent; starting an improvement lane; `lane.sh dismiss`.

**Merged lanes.** Auto-merge is separate from AFK (the `auto-merge` skill): when it is on for a lane, `bash "../../scripts/merge.sh" run --lane L --repo R` merges after its own checks and records it. When the scope has worktree removal and a cleanup question is waiting, `bash "../../scripts/cleanup.sh" run --afk --lane L --repo R` removes the worktree only if all of its nine checks hold, and records it; on `AFK WAIT` the lane waits for the user.

These are written rules: no hook blocks a command. Follow them exactly.

## When the user is back

A message that is really theirs while AFK is on (the hook adds a reminder; the watcher's `graph:` messages, agents' output and other sessions never count; a panel answer is theirs):

1. Show `bash "../../scripts/decide.sh" digest --session <session>` first, the table as it is.
2. Ask "still away?" in one AskUserQuestion: "Yes, stay AFK" or "No, I'm back". Under yes, do what they asked and stay on.
3. On no, or on `/herdr-graph-engineering:afk off`: `session.sh afk off`, show the digest if not shown, `decide.sh seen`, then ask what waited, as the orchestrate skill's "When an event arrives" says.
