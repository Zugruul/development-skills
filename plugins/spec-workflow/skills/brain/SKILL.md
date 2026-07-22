---
name: brain
description: Inspect and tend the per-identity zettel brains — status/recall/mint/prune/directory/graduate-check/explain/path via brain.sh. Orchestrator-only memory (each role's brain is private; subagents never read one). Use to see what a role has learned, recall lessons for a task, mint a retro note, prune stale links, explain why one note matters, find the shortest link path between two notes, or regenerate the directory. Bare invocation shows the directory + per-brain note counts.
allowed-tools: Bash
---

# Identity brains — status / recall / tend

`brain.sh` = `bash "../../scripts/brain.sh"`. **Only the orchestrator touches brains** — each role's brain is private; subagents receive recall output as pasted text and never read a brain path. Full protocol: `../../skills/build-next/references/brains.md`.

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
recall <role> --query "TERM ..." [--limit N]
                                   # PRECISE boolean filter over frontmatter fields — not
                                   # fuzzy recall. See "Precise queries" below.
mint <role> <slug> --tags a,b --paths "x/**" --source "PR#N ..." [--learned-from R --source-note S] [--entities "card:x,card:y"]
                                   # body on stdin; re-mint bumps strength; auto-links [[wikilinks]];
                                   # --entities declares real-world entities (kind:slug) this note is
                                   # ABOUT, for the cross-identity correlation index below — like
                                   # tags/paths, must be re-passed on every re-mint to persist
directory                          # regenerate DIRECTORY.md (titles + tags only)
status <role>                      # per-role note listing (same lines as directory) plus a
                                   # compact outcome tally per note (`3✓ 1✗ 1⚠`) when it has
                                   # recorded outcomes; a note with no outcomes renders
                                   # identically to directory's line for it
entity-index                       # regenerate .claude/identities/entity-index.json from every role's
                                   # entities: frontmatter (frontmatter-only, derived, commit it like
                                   # DIRECTORY.md); symlinked notes attribute to their physical home role
                                   # only. Never read by recall/query — a whole-brain/visualization join
                                   # only (ask-brain, neural-view). Run at retro time alongside directory.
consult <consumer> <owner> <slug>  # print owner's note for a one-time paste; logs to owner; recurs on 2nd
prune <role> [--apply] [--force]   # flag stale links (never-fired+aged, target graduated/missing);
                                   # --apply removing >methodology.shrinkGuardFraction (default 30%)
                                   # of the brain's links refuses unless --force is given (shrink
                                   # guard, SPEC-GRAPHIFY §13; a small-brain floor exempts tiny prunes)
retro-mark                         # bump the retro counter that ages notes for pruning
graduate <role> <slug>            # mark a proven lesson graduated (no longer injected; still bridges)
graduate-check [role] [--threshold N]
                                   # READ-ONLY: list notes at/above the graduation threshold
                                   # (methodology.graduationThreshold, default 3) with a proposed
                                   # destination (ROLE.md rule / specs[].invariants entry /
                                   # test-or-lint); never mutates a note — graduate stays the call
explain <role> <slug>              # READ-ONLY interrogation card for ONE note: full body, the
                                   # exact recall header (confidence + outcome tally +
                                   # contested/stale), a community placeholder (pending GL-030),
                                   # every inbound/outbound link with weight/fires/last, and the
                                   # top 5 co-activated notes from a 2-hop spread seeded on just
                                   # this note — never bumps links.json (unlike recall)
path <role> <slug-a> <slug-b>      # READ-ONLY shortest link path (BFS over links.json, stdlib);
                                   # links are UNDIRECTED for pathfinding — the stored from->to
                                   # direction is a mint-order artifact, not a traversal
                                   # constraint; deterministic sorted-slug tie-break on equal-
                                   # length paths; prints "no path" (exit 0) when disconnected;
                                   # A->A prints the single slug; never bumps links.json
```

## Precise queries (`recall --query`)
Plain `recall` is fuzzy: any tag/path overlap seeds it, then activation spreads along
`[[wikilinks]]` and everything within budget gets injected — good for "what's relevant
here," wrong for "give me exactly the notes matching X and not Y." `--query` is the
precise counterpart: no activation spreading, no token budget, no link-touching — it's a
straight boolean filter over each note's frontmatter, returning every match (or `--limit N`
of them) as `slug — label` lines.

Grammar — space-separated terms, ALL must hold (AND):
- `word` — `word` is one of the note's `tags`
- `field:value` — `value` is present in frontmatter field `field` (works whether that
  field is a scalar or a list in the note)
- `field:v1,v2` — OR *within* one field: v1 present OR v2 present
- a leading `-` on either form negates that term

Example — "non-attack Action cards for Warrior at Majestic rarity that interact with Axe"
(a compound AND/NOT/OR query no amount of fuzzy `--keywords` overlap can express):
```bash
recall card-vault --query "types:Action -subtypes:Attack classes:Warrior rarity:Majestic interacts-with:Axe"
```
This only works as well as the frontmatter a role's generator writes — it queries whatever
fields exist (`tags` always; anything else is role-specific, e.g. card-vault's `types`/
`subtypes`/`classes`/`rarity`/`interacts-with`). Use it when you need an exact filtered
list; use plain `recall` when you want associative "what's relevant" retrieval.

## When to use
- **Recall** — assembling a dev/reviewer brief: run `recall <role>` with the task's expected paths + keywords and paste the output under `## LESSONS (recalled)`.
- **Precise lookup** — answering a compound "which notes match X and not Y" question: use `recall <role> --query "..."` instead of guessing at `--keywords` overlap.
- **Retro** (at each PR close) — `mint` new notes in your own wording, `prune`, `graduate` proven ones, `retro-mark`, `directory`, then commit as the orchestrator identity (`identity.sh orchestrator`).
- **Consult** — a report asked `CONSULT <role>: <slug>`: run `consult` and paste the body once; a 2nd hit prints a RECURRENCE reminder to mint it into the consumer's own brain.
- **Explain** — debugging "why does this note matter/rank/link the way it does": run `explain <role> <slug>` for a self-contained card (body, header, links, co-activation) instead of piecing it together from `recall`/`status`/`directory` output by hand.
- **Path** — debugging "how/why are these two notes connected": run `path <role> <slug-a> <slug-b>` for the shortest link chain instead of tracing `explain`'s link lists by hand.

## Rules
- Notes are atomic: one idea, a few lines. Link related notes with `[[slug]]`.
- Never expose one role's brain to another except via a deliberate `consult`.
- `.activation.jsonl` is a frozen contract (a live viewer parses it) — don't hand-edit it.
