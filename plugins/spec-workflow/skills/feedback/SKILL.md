---
name: feedback
description: Records structured agent feedback about the WORKFLOW itself (not the project being built) — what worked, what caused friction, incidents, recommendations — into the loop feedback feed for later triage. Use at the end of a build-loop iteration when methodology.feedback is enabled.
allowed-tools: Bash
---

# Feedback — emit a structured process-feedback record

The feed lives at `.claude/feedbacks/` (adjacent to `project.yaml`) — a tracked archive, committed and pushed alongside code by default (opt out only via the repo's own `.gitignore`). Like the identity brains, it is orchestrator-mediated only: no dev/reviewer subagent ever reads or writes it directly — this skill (run by the orchestrator) is the sole path in.

`methodology.feedback` (`true` shorthand or `{enabled, feed, roles, autoTriage}`) gates this skill. Check first:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/feedback.py" "$(git rev-parse --show-toplevel)" status
```

If it reports `feedback: disabled`, say so and stop — do nothing else.

## When enabled

1. **Reflect on the ITERATION, not the project.** For each notable thing, ask: did the *workflow* (a skill, a script, a protocol, permissions, review, merge, briefing, board mechanics) help or hurt? Categories: `worked-well`, `friction`, `incident`, `recommendation`. Never file feedback about the project's own code/product — that's a normal board issue or a retro brain note about the project, not this feed.
2. **Write the record to a temp file** matching the schema documented in `scripts/feedback.py`'s module docstring (`schemaVersion`, `kind`, `ts`, `iteration`, `source`, `items[]`). For every item, fill `generalized` with a restatement that could apply to ANY project using this plugin — no task ids, no `#N` issue/PR references, no repo-specific names. If an item is genuinely local-only, leave `generalized: ""` (it will only ever be routable as `ignore`).
3. **Emit it:**
   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/feedback.py" "$(git rev-parse --show-toplevel)" emit /path/to/record.yaml
   ```
   A rejection (`INVALID: ...`) means the generalization contract failed (a task id or `#N` ref leaked into `summary`/`generalized`) or the record is malformed — fix the file and re-emit; never weaken the item to force it through.
4. **Report** the emit result and the current pending count (`feedback.py <root> status`).

## Triage (retro time)

Triage — dedupe, routing, board-item creation — is the ORCHESTRATOR's job, done as part of the retro step in `build-next` (see `skills/build-next/SKILL.md` and `references/brains.md`). This skill only emits; it never routes.
