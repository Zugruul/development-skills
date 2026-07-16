---
name: feedback
description: Records structured agent feedback about the WORKFLOW itself (not the project being built) — what worked, what caused friction, incidents, recommendations — into the loop feedback feed for later triage. Use at the end of a build-loop iteration when methodology.feedback is enabled.
allowed-tools: Bash
---

# Feedback — emit a structured process-feedback record

The feed lives at `.claude/feedbacks/` (adjacent to `project.yaml`) — a tracked archive, committed and pushed alongside code by default (opt out only via the repo's own `.gitignore`). Like the identity brains, it is orchestrator-mediated only: no dev/reviewer subagent ever reads or writes it directly — this skill (run by the orchestrator) is the sole path in.

`methodology.feedback` (`true` shorthand or `{enabled, feed, roles, autoTriage}`) gates this skill. Check first:

```bash
python3 "../../scripts/feedback.py" "$(git rev-parse --show-toplevel)" status
```

If it reports `feedback: disabled`, say so and stop — do nothing else.

## When enabled

1. **Reflect on the ITERATION, not the project.** For each notable thing, ask: did the *workflow* (a skill, a script, a protocol, permissions, review, merge, briefing, board mechanics) help or hurt? Categories: `worked-well`, `friction`, `incident`, `recommendation`. Never file feedback about the project's own code/product — that's a normal board issue or a retro brain note about the project, not this feed.
2. **Write the record to a temp file** matching the schema documented in `scripts/feedback.py`'s module docstring (`schemaVersion`, `kind`, `ts`, `iteration`, `source`, `items[]`). For every item, fill `generalized` with a restatement that could apply to ANY project using this plugin — no task ids, no issue/PR references bare OR qualified (neither `#N` nor `some-repo#N`), no repo-specific names. If an item is genuinely local-only, leave `generalized: ""` (it will only ever be routable as `ignore`). `evidence[]` and `routing.ref`, in contrast, are exactly where a task ref belongs — you may write it bare (`#71`) and `emit` will qualify it to `<project.name>#71` for you.
3. **Emit it:**
   ```bash
   python3 "../../scripts/feedback.py" "$(git rev-parse --show-toplevel)" emit /path/to/record.yaml
   ```
   A rejection (`INVALID: ...`) means the generalization contract failed (a task id or an issue/PR ref, bare or qualified, leaked into `summary`/`generalized`) or the record is malformed — fix the file and re-emit; never weaken the item to force it through.
4. **Report** the emit result and the current pending count (`feedback.py <root> status`).

## Qualified references

A multi-project archive makes a bare `#71` ambiguous — is it this repo's issue 71, or another project's? `emit` and `route` both normalize bare `#N` in `items[].evidence[]` and `items[].routing.ref` to `<project.name>#N`, reading `project.name` from THIS repo's own `.claude/project.yaml`. A ref another project already qualified (`comm-platform#71`, `event-sorc#22`, ...) passes through untouched — qualification never rewrites someone else's ref, and is a no-op if run twice.

An existing feed predating this contract can be brought into line with a one-shot, surgical migration that touches only bare refs in `evidence[]`/`routing.ref` and leaves every other byte (comments, quoting, `summary`/`generalized`/`detail` text) alone:

```bash
python3 "../../scripts/feedback.py" "$(git rev-parse --show-toplevel)" migrate-qualify
```

Idempotent — safe to re-run; a clean feed reports `OK: no changes`.

## Triage (retro time)

Triage — dedupe, routing, board-item creation — is the ORCHESTRATOR's job, done as part of the retro step in `build-next` (see `skills/build-next/SKILL.md` and `references/brains.md`). This skill only emits; it never routes.

## Standalone invocation — offer a retrospective now

When a human explicitly runs `/feedback` outside a `build-next` iteration (no PR just closed, no retro about to happen), that record's `brain-note`-worthy items will sit unrouted until some future retro — which, if this repo's loop never reaches one (e.g. no `.claude/identities/` orchestrator identity, or the loop simply isn't run that way), means they **never** get minted; this is exactly how two live repos silently accumulated dozens of task-closes with zero brain notes. So after step 4's report, **offer** (don't just assume a later retro will catch it):

"Also run a retrospective now (dedupe, route, and mint any brain-note items from pending feedback) — since there's no PR/retro boundary here to catch it later?"

If the human says yes, run the `retrospective` skill. Decline is fine — the items simply remain pending for the next retro, same as today.
