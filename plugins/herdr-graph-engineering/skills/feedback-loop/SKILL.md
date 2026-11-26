---
name: feedback-loop
description: Turns the graph engineering feedback loop on or off for this orchestrator session (off by default) - when on, the orchestrator collects notes from itself and each lane's agents before the lane is cleaned up on how the whole flow could have been better, and turns them into general lessons for improvement pull requests to this plugin, never committing any detail of the tasks. Use for '/herdr-graph-engineering:feedback-loop', 'turn the feedback loop on', 'stop collecting feedback', 'is the feedback loop on'.
---

# Feedback loop: on or off for this session

Paths are relative to this `SKILL.md`; the scripts are in `../../scripts/`. Works in Claude Code, OpenCode and Codex.

The feedback loop is **off by default**. The choice holds for one orchestrator session and is stored in that session's file (`session.sh`), so it survives a compaction; a new session starts off again.

## Toggle it

1. Find the session: `bash "../../scripts/session.sh" find --pane "$HERDR_PANE_ID"` prints its name (no output: use `graph`). Show the current state: `bash "../../scripts/feedback.sh" state --session <name>` prints `FEEDBACK on` or `FEEDBACK off`.
2. If the user already said on or off (the argument `$ARGUMENTS`, or their message), use that. Otherwise ask once. With a question tool (AskUserQuestion in Claude Code, the question tool in OpenCode) ask "Turn the feedback loop on for this session?" with two options: **Off** first (the default: nothing is collected) and **On** (before each lane is cleaned up, its live agents and the orchestrator write how the whole flow could have been better; general lessons can later become pull requests to this plugin). Without a question tool (Codex), ask the same question in plain text and wait for the answer. No answer counts as off.
3. Record it: `bash "../../scripts/session.sh" set --key feedback --value on --session <name>` (or `off`). With no session file yet this creates it; the orchestrator fills in its pane at its start.
4. Say in one line what is now on or off.

## What on means

The `orchestrate` skill holds the steps (its section "Feedback loop"). In short:

- **Before a lane is cleaned up**, `cleanup.sh` prints `FEEDBACK <lane>` and refuses `cleanup.sh run` until the orchestrator asked the lane's still-live agents how the whole flow (pattern, roles, briefs, gates, reviews, panel, scripts, orchestrator behaviour) could have been better, and wrote its own note: `feedback.sh add --from orchestrator --lane <lane> --text ...`.
- **Raw notes stay outside every repository**, in the user's state folder (`feedback.sh path`). They may hold task details; they never leave that folder.
- **Lessons** are general rules the orchestrator writes from the notes. `feedback.sh lesson` stores one only when the sanitiser finds no task detail in it: never a detail of a task (repository or service names, paths, branches, pull request or ticket numbers, links, commit ids, code, people, emails, secrets, the user's own words).
- **Improvement lanes**: from time to time, or when the user asks, the orchestrator offers to open a lane in the plugin's own repository whose brief is the open lessons only. It edits only the plugin's instructions, skills, roles, patterns and scripts.

Turning it off stops collecting; notes and lessons already written stay in the state folder (`feedback.sh show`).
