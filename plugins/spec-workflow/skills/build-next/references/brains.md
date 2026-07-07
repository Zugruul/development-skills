# Per-identity brains — the memory protocol

Each identity (dev / reviewer / orchestrator, extensible) owns a **private** brain of
atomic zettel notes under `<identities-dir>/<role>/brain/` (default identities dir
`.claude/identities`). Brains give each role durable memory that evolves separately —
a hard product requirement. **Only the orchestrator process ever reads or writes a
brain.** Subagents never see a brain path; recalled lessons reach them as pasted text.

`brain.sh` = `bash "${CLAUDE_PLUGIN_ROOT}/scripts/brain.sh"` (resolves the repo root from
git; writes into `<root>/.claude/identities/`).

## Layout (per role)
```
.claude/identities/
  DIRECTORY.md                     # regenerated map: titles + tags only, never bodies
  retros.log                       # one line per retro (bumped by retro-mark)
  <role>/
    ROLE.md                        # stable, human-owned: mission / boundaries / escalation
    brain/
      notes/<slug>.md              # atomic zettels (frontmatter + a few lines)
      links.json                   # {"from->to": {"weight":0.5,"fires":4,"last":"..."}}
      .activation.jsonl            # append-only recall/consult event log (frozen contract)
      consults.json                # recurrence counters for cross-role consults
```

## Note format
```markdown
---
tags: [yaml, config]
paths: ["scripts/**", "**/*.yaml"]
strength: 3
source: "PR#3 review round 1"
learned-from: reviewer          # optional — provenance of a consulted lesson
source-note: yaml-dump-key-order # optional
graduated: false
created: 2026-07-07
---
One idea, a few lines max.

Related: [[other-slug]] [[another-slug]]
```
Links are `[[slug]]` wikilinks (Obsidian-compatible). Weight/fires/last live in
`links.json` so notes stay clean markdown for humans.

## Injecting recall into every brief
When briefing a dev or reviewer subagent, assemble:

- `## YOUR ROLE` — the role's `ROLE.md` **verbatim**.
- `## LESSONS (recalled)` — the output of
  `brain.sh recall <role> --paths "<task's expected paths, comma-sep>" --keywords "<task keywords>" [--budget 600]`,
  plus the relevant slice of `DIRECTORY.md` so the agent knows what else exists.
- The **consult instruction**: "To confirm a lesson, request `CONSULT <role>: <slug>`
  in your report. Never read any brain path directly."

Recall uses **spreading activation**: notes whose `paths` glob-match a task path or whose
`tags` intersect the keywords are seeded (activation `1.0 × (1 + strength/10)`); activation
then flows along links (neighbor = source × 0.5 × weight, 2 hops), keeping the max per note;
the strongest notes are emitted full-body, medium ones as a one-liner, weak ones as a title,
stopping at the token budget. Graduated notes are excluded from injection but still bridge
links. Every recall appends `seed`/`hop`/`inject` events to `.activation.jsonl` and bumps
`fires`/`last` on traversed links.

## Retro at each PR close
After a PR merges (or is set aside), the orchestrator runs a retro:

1. Interview the dev and reviewer agents: what surprised them, what they'd tell their future
   self, what the review caught.
2. `brain.sh mint <role> <slug> --tags ... --paths ... --source "PR#N ..."` — mint notes in
   **your own wording** (body on stdin), one idea each, wikilinking related slugs. Re-minting
   an existing slug bumps its `strength`.
3. `brain.sh prune <role>` — review flagged links (never-fired + aged, or target
   graduated/missing); `--apply` to remove. `brain.sh retro-mark` bumps the retro counter that
   ages notes for pruning.
4. `brain.sh graduate <role> <slug>` — a lesson proven durable graduates; enforcement then
   moves to `ROLE.md`, an invariant, or a lint rule (the caller decides where). Graduated notes
   stop being injected but still bridge links.
5. `brain.sh directory` — regenerate `DIRECTORY.md`.
6. Commit the brain changes as the **orchestrator** identity
   (`identity.sh orchestrator` flags line).

## Consult + recurrence
A subagent can't read another role's brain. When its report requests `CONSULT <role>: <slug>`,
the orchestrator runs `brain.sh consult <consumer-role> <owner-role> <slug>`: it prints the
owner's note body (paste it one-time into the consumer's next brief) and logs a `consult` event
to the **owner's** activation log. The **second** consult of the same (consumer, slug) pair
prints `RECURRENCE: consider minting into <consumer>'s brain (learned-from: <owner>)` — a signal
the lesson should become the consumer's own note (set `learned-from`/`source-note`).

## Frozen contract — `.activation.jsonl`
Each line is one JSON object; a parallel live viewer parses this format, so **do not deviate**:
```
{"ts": "<iso>", "role": "<role>", "event": "seed"|"hop"|"inject"|"consult", "note": "<slug>", "activation": <float> (seed/hop/inject only), "link": "from->to" (hop only), "consumer": "<role>" (consult only)}
```
`consult` events carry no `activation` (there is no retrieval score for a manual paste); the viewer reads every field defensively.
