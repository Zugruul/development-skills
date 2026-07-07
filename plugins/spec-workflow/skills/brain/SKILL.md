---
name: brain
description: Inspect and tend the per-identity zettel brains — status/recall/mint/prune/directory via brain.sh. Orchestrator-only memory (each role's brain is private; subagents never read one). Use to see what a role has learned, recall lessons for a task, mint a retro note, prune stale links, or regenerate the directory. Bare invocation shows the directory + per-brain note counts.
allowed-tools: Bash
---

# Identity brains — status / recall / tend

`brain.sh` = `bash "${CLAUDE_PLUGIN_ROOT}/scripts/brain.sh"`. **Only the orchestrator touches brains** — each role's brain is private; subagents receive recall output as pasted text and never read a brain path. Full protocol: `${CLAUDE_PLUGIN_ROOT}/skills/build-next/references/brains.md`.

## Bare invocation (status)
Regenerate and show the map, plus how many notes each role holds:
```bash
brain.sh directory && cat .claude/identities/DIRECTORY.md
for d in .claude/identities/*/brain/notes; do echo "$(dirname "$(dirname "$d")" | xargs basename): $(ls "$d" 2>/dev/null | wc -l | tr -d ' ') note(s)"; done
```

## Subcommands
```
recall <role> --paths "a/b.sh,c/**" --keywords "yaml,merge" [--budget 600]
                                   # spreading-activation retrieval → paste into a brief
mint <role> <slug> --tags a,b --paths "x/**" --source "PR#N ..." [--learned-from R --source-note S]
                                   # body on stdin; re-mint bumps strength; auto-links [[wikilinks]]
directory                          # regenerate DIRECTORY.md (titles + tags only)
consult <consumer> <owner> <slug>  # print owner's note for a one-time paste; logs to owner; recurs on 2nd
prune <role> [--apply]             # flag stale links (never-fired+aged, target graduated/missing)
retro-mark                         # bump the retro counter that ages notes for pruning
graduate <role> <slug>            # mark a proven lesson graduated (no longer injected; still bridges)
```

## When to use
- **Recall** — assembling a dev/reviewer brief: run `recall <role>` with the task's expected paths + keywords and paste the output under `## LESSONS (recalled)`.
- **Retro** (at each PR close) — `mint` new notes in your own wording, `prune`, `graduate` proven ones, `retro-mark`, `directory`, then commit as the orchestrator identity (`identity.sh orchestrator`).
- **Consult** — a report asked `CONSULT <role>: <slug>`: run `consult` and paste the body once; a 2nd hit prints a RECURRENCE reminder to mint it into the consumer's own brain.

## Rules
- Notes are atomic: one idea, a few lines. Link related notes with `[[slug]]`.
- Never expose one role's brain to another except via a deliberate `consult`.
- `.activation.jsonl` is a frozen contract (a live viewer parses it) — don't hand-edit it.
