---
name: feedback-loop
description: Turns the graph engineering feedback loop on or off for this orchestrator session (off by default) - when on, the orchestrator collects notes from itself and each lane's agents before the lane is cleaned up on how the whole flow and how the repository's documentation could have helped more, and turns them into general lessons for improvement pull requests to this plugin and to that repository's documentation, never committing any detail of the tasks. Use for '/herdr-graph-engineering:feedback-loop', 'turn the feedback loop on', 'stop collecting feedback', 'is the feedback loop on'.
---

# Feedback loop: on or off for this session

Paths are relative to this `SKILL.md`; the scripts are in `../../scripts/`. Works in Claude Code, OpenCode and Codex.

The feedback loop is **off by default**. The choice holds for one orchestrator session and is stored in that session's file (`session.sh`), so it survives a compaction; a new session starts off again.

## Toggle it

1. Find the session: `bash "../../scripts/session.sh" find --pane "$HERDR_PANE_ID"` prints its name (no output: use `graph`). Show the current state: `bash "../../scripts/feedback.sh" state --session <name>` prints `FEEDBACK on` or `FEEDBACK off`.
2. If the user already said on or off (the argument `$ARGUMENTS`, or their message), use that. Otherwise ask once. With a question tool (AskUserQuestion in Claude Code, the question tool in OpenCode) ask "Turn the feedback loop on for this session?" with two options: **Off** first (the default: nothing is collected) and **On** (before each lane is cleaned up, its live agents and the orchestrator write how the whole flow, and the repository's documentation, could have been better; general lessons can later become pull requests to this plugin and to that documentation). Without a question tool (Codex), ask the same question in plain text and wait for the answer. No answer counts as off.
3. Record it: `bash "../../scripts/session.sh" set --key feedback --value on --session <name>` (or `off`). With no session file yet this creates it; the orchestrator fills in its pane at its start.
4. Say in one line what is now on or off.

## What on means

The `orchestrate` skill holds the steps (its section "Feedback loop"). In short:

- **Before a lane is cleaned up**, `cleanup.sh` prints `FEEDBACK <lane>` and refuses `cleanup.sh run` until the orchestrator asked the lane's still-live agents how the whole flow (pattern, roles, briefs, gates, reviews, panel, scripts, orchestrator behaviour) could have been better, and wrote its own note: `feedback.sh add --from orchestrator --lane <lane> --text ...`.
- **Two targets, kept apart**: notes and lessons about the plugin's flow (the default), and notes and lessons about the repository's documentation the lane worked in (`--target repo --repo R`: its agent instructions, READMEs and docs: missing or wrong guidance, rules agents tripped over, context that was hard to find, too much or too little to read, commands that did not work as documented). Each improvement lane gets only its own target's lessons.
- **What helped is asked too**: which guidance helped or prevented a mistake. A note that someone read something and did not need it never becomes a deletion by itself.
- **Raw notes stay outside every repository**, in the user's state folder (`feedback.sh path`). They may hold task details; they never leave that folder.
- **Lessons** are general rules the orchestrator writes from the notes. `feedback.sh lesson` stores one only when the sanitiser finds no task detail in it: never a detail of a task (repository or service names, paths, branches, pull request or ticket numbers, links, commit ids, code, people, emails, secrets, the user's own words).
- **Improvement lanes**: from time to time, or when the user asks, the orchestrator offers a lane whose brief is the open lessons of one target only. In the plugin's own repository it edits only the plugin's instructions, skills, roles, patterns and scripts. In a repository the lanes worked in it edits only that repository's documentation (`AGENTS.md`, `CLAUDE.md`, READMEs, docs), following that repository's own rules for pull requests. A repository lesson is held to a harder bar: it must help other tasks there, so it never names the task, ticket, pull request, branch, service-specific bug or data that produced it, and holds no identifiers or code.
- **Keeping what is there**: improvement lanes add and extend. They run the `improve` pattern, whose second agent checks that existing expertise is preserved, and the orchestrator runs its own copy of the preservation check (`guard.sh`), which reports every instruction sentence removed, changed or moved; only the user's yes, per finding, allows one.
- **Lessons keep their support**: each names the notes and lanes behind it, and counts as used only after its pull request merged.

Turning it off stops collecting; notes and lessons already written stay in the state folder (`feedback.sh show`).
