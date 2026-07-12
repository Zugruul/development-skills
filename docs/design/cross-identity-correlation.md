# Cross-identity correlation layer — design proposal

Status: DESIGN RESOLVED — open questions answered by the human 2026-07-12 (see §6).
Implementation not yet started. Board item: #163.
Date: 2026-07-12. Investigated against development-skills@main (a2cbcaf) and fab-cli@origin/main.

## 1. Verified current state (brief confirmed, with corrections)

- `brain.py cmd_recall` seeds from the ONE role's notes (tags/paths), spreads only along that
  role's `links.json`, renders only slugs present in that role's own `notes` dict
  (`brain.py:401-404` — a foreign target slug is silently skipped). Confirmed.
- `cmd_mint` auto-links `[[wikilinks]]` into the same role's `links.json` only. Confirmed.
- `ask-brain` = per-role `recall --keywords` + manual blending in the agent's head; nothing
  persisted; correlation only via incidental tag overlap. Confirmed.
- **Correction/extension 1:** there is already a sanctioned cross-identity *read* primitive:
  `brain.py consult <consumer> <owner> <slug>` — reads the owner's note body, counts recurrence
  in the consumer's `consults.json`, logs a `consult` event to the owner's `.activation.jsonl`.
  Neural-view already derives a **cross-brain edge type** from those events (`build_graph`,
  `neural-view.py:409-423`, `"type": "consult"`) and renders it as a curved arc between role
  clusters (`templates/neural-view.html:1269-1281`). So both the data path and the renderer
  already have a precedent for a second, visually distinct, boundary-crossing edge type —
  but only role→role, never note→note.
- **Correction/extension 2:** `cmd_prune` treats any link whose target is not in the role's own
  notes as `"target missing"` — an immediate prune candidate (`brain.py:599-601`). This is a
  hard argument against option (b) below: cross-identity keys stored in `links.json` would be
  auto-destroyed by existing maintenance.
- Synapse lines in the client are drawn with `vertexColors: true`
  (`neural-view.html:1236`), so a per-edge two-color gradient (source vertex = brain A's
  color, target vertex = brain B's color) is natively supported by the existing material.
- The `kw-*` corpus: one physical copy in card-vault, relative-symlinked into judge and player
  (`keyword-sync.py`), manifest-guarded, editorial authority stays with the judge. Confirmed.

## 2. Empirical scope (fab-cli @ origin/main)

Brains: card-vault 5,051 notes (4,863 `card-*`), judge 618 (430 own + 188 kw symlinks),
player 287 (99 own), dev 3, reviewer 2, orchestrator 22. (`lore-vault` exists only on an
in-flight feature branch, with 399 notes — the design must cover it too.)

- **14.7%** of `card-*` notes (715/4,863) have zero edges of any kind in card-vault's own
  `links.json` (fully isolated neurons even before considering cross-brain).
- **Zero** `[[card-*]]` wikilinks exist anywhere in judge or player notes → **zero** stored
  note-level cross-brain relations today, for any card.
- Tag overlap (the only thing ask-brain can currently exploit) is nearly useless in practice:
  only 2/430 judge notes carry a tag that string-equals a card slug, partly because main's
  card slugs are per-color (`card-gone-in-a-flash-red`) while judge tags name the design
  (`gone-in-a-flash`). Slug-scheme drift breaks even lucky matches. (The in-flight branch
  consolidates pitch variants into one name-level slug, changing ~1,700 slugs — any
  correlation keyed on *note slugs* would break twice; keys must be slug-scheme-independent.)
- The latent correlation the system cannot see: **122/430 judge notes** and **60/99 player
  notes** mention at least one card display name in prose — ~438 judge note↔card pairs
  (301 distinct cards) and ~128 player pairs (96 cards). The symptom is systemic, as suspected.

## 3. Recommended design: declared entities + a generated repo-level index

Recommendation is a refined option (a). Reject (b) — see §3.4.

### 3.1 Entity declarations (frontmatter, per note, owned by the note's brain)

A new optional frontmatter list field on notes:

```yaml
entities: [card:gone-in-a-flash, card:fleeing-starbreeze]
```

- Key format `kind:slug`; kinds initially `card`, `keyword`, `hero` (lore-vault); open set.
- The slug is the **name-level** kebab of the real-world entity (variant-agnostic), NOT a note
  slug — immune to per-color→merged note-slug migrations and to which brain hosts which note.
- Each brain declares only what **its own** notes are about. Nothing in another brain changes.
  This is what makes correlation reliable-by-construction instead of lucky-string-overlap:
  generators emit it deterministically, hand-minted notes declare it at mint time.
- `brain.py`: `mint` gains `--entities "card:x,card:y"`; `entities` joins `KEY_ORDER` (after
  `paths`); `parse_note`/`render_note` already handle list fields.

### 3.2 The generated index: `.claude/identities/entity-index.json`

Built by a new `brain.py entity-index` command (sibling of `directory`, same tone: generated,
never hand-edited, committed like `DIRECTORY.md`, regenerated at retro time and by the
builders). One frontmatter-only scan of all brains (~5k files, well under a second; symlinked
notes attribute to their physical home role only, so kw notes don't triple-count).

```json
{
  "generated-by": "brain.py entity-index",
  "entities": {
    "card:gone-in-a-flash": {
      "anchor": "card-vault/card-gone-in-a-flash",
      "notes": [
        ["card-vault", "card-gone-in-a-flash"],
        ["judge", "ix-fleeing-starbreeze-x-gone-in-a-flash"],
        ["judge", "ix-gone-in-a-flash-general"]
      ]
    }
  }
}
```

- `anchor` = the entity's canonical fact note, resolved by per-kind home-role config
  (`card`→card-vault, `keyword`→card-vault physical home, `hero`→lore-vault), declared in
  `project.yaml` under a new `methodology.entityKinds` map; entities with no anchor note just
  have `anchor: null`.
- **Fan-out control:** consumers draw/traverse anchor↔member pairs (a star), not all-pairs —
  `keyword:ward` with 200 referencing notes yields 200 edges, not 19,900.

### 3.3 Who reads the index (and who never does)

- **Per-role `recall`: never.** Spreading activation, seeding, budget, links.json mutation —
  all completely unchanged. A role's own recall cannot be polluted by another brain, full stop.
- **`ask-brain`:** after the existing per-role recalls, take the union of recalled notes'
  `entities`, look each up in the index, and **`consult`** the correlated notes in other roles
  through the existing primitive — so every boundary crossing stays logged in the owner's
  activation log, recurrence-counted in the consumer, and attributed per-role in the answer
  (the skill already requires "say which role it came from"). New step 3 in the skill,
  ~10 lines of prose; no new read mechanism invented.
- **`ask-identity`: awareness, never auto-consult** (human decision, §6.2). The skill may
  read the index to say "the judge's brain holds N notes about card:X" and point at
  `/spec-workflow:ask-identity judge ...` or a `consult` — but it never pulls the other
  brain's content into its answer on its own. Identities answer from their own notes only;
  they can be AWARE that another identity holds information and ASK it (consult is exactly
  that ask — logged, recurrence-counted), and they can then LEARN from what they were told by
  minting into their own brain with `learned-from`/`source-note` provenance. They never step
  over the boundary silently.
- **neural-view:** `build_graph` loads `entity-index.json` per repo (falling back to deriving
  pairs from frontmatter on the fly if the file is absent/stale-looking, so the view never
  requires a regen) and emits note-level `{"type": "entity", "entity": "card:...", source,
  target}` edges for **cross-role** anchor↔member pairs only (same-role pairs are links.json's
  business). Client: entity edges are excluded from the physics/synapse layer like consult
  edges are today, drawn as a distinct line style (thin, dashed feel via opacity/curve),
  **colored as a gradient between the two brains' role colors** — the synapse material already
  uses `vertexColors: true`, so this is: source vertex ← role A color, target vertex ← role B
  color. Color is configurable: `neuralView.entityEdgeColor` in `project.yaml` — `"gradient"`
  (default) or any CSS color to force a flat color; role colors themselves keep coming from
  `delegation.identities.<role>.color`. **Zero-physics rule (human directive 2026-07-12):**
  entity edges are render-only — they must never enter the force-simulation `links` array or
  contribute any force, so identity clusters do not pull each other and the layout with entity
  edges present is identical to today's. Pinned by test.

### 3.4 Why not option (b) (cross-identity keys inside links.json)

- `cmd_prune` would flag every such edge `"target missing"` and delete it (§1, correction 2).
- `cmd_recall` fires/bumps `links.json` edges during traversal — either it starts writing
  metadata about foreign-note relations into a role's private editorial file, or it needs
  special-casing everywhere; both erode the "one role per command" invariant stated at the
  top of `brain.py`.
- links.json is the role's editorial property; a generated correlation doesn't belong in a
  hand-accountable file. The index is a separate, regenerable artifact — like `DIRECTORY.md`.
- The `kw-*` symlink precedent is the other extreme (shared bytes) and doesn't generalize:
  judge rulings must NOT become player-visible-as-own-notes. The index shares *metadata about
  aboutness*, never note content — strictly weaker than both symlinks and merged graphs.

### 3.5 Isolation & the "judge never learns from the player" rule

- The index stores no note content — only (entity, role, slug) tuples. Reading a correlated
  note still requires `consult`, which was already the sanctioned, logged, orchestrator/skill-
  driven cross-read. Nothing new can be read that couldn't be read before; it's now *findable*.
- Per-role recall never touches the index (§3.3), so no role's automatic context injection can
  ever include foreign material. The correlation is a query-time join for whole-brain
  consumers only.
- Minting remains governed by existing provenance rules (`learned-from`/`source-note`,
  consult-recurrence prompting, each role's ROLE.md editorial protocol). A judge answering via
  ask-brain may *cite* a player note as "player's perspective" but mints into the judge brain
  only through the judge's own verification protocol — unchanged and unweakened.
- A player note declaring `entities: [card:x]` changes nothing inside the judge brain — not
  its notes, links, or recall. Worst case it adds one dashed edge in a visualization and one
  extra logged consult in a whole-brain answer, both attributed.

## 4. fab-cli population scripts (to be fixed as part of this, TDD)

- **`scripts/build-card-vault.py`:** emit `entities: [card:<name-level-kebab>]` on every
  generated card note (the same design-level kebab the in-flight consolidation uses for
  merged slugs — one honest source for it, shared helper). Namesake disambiguation
  (`hyper-driver` vs `hyper-driver-token`) reuses the note-slug disambiguator minus the
  `card-` prefix. `check` must diff entities like any other generated content. After writing
  notes, invoke (or replicate) `entity-index` regeneration so build leaves the index fresh.
- **`scripts/keyword-sync.py`:** emit `entities: [keyword:<slug>]` on kw notes (physical copy
  only; mirrors are symlinks and inherit it); `sync` regenerates the index; `check` verifies
  index freshness for keyword entries the same way it verifies `keywords-index.md`.
- **`scripts/build-lore-vault.py`** (feature branch): same pattern with `hero:`/`card:` keys.
- **Backfill for hand-minted notes (judge/player):** a one-shot `scripts/backfill-entities.py`
  that PROPOSES `entities:` per note from (i) tags ∩ card-name set, (ii) display-name prose
  matches (the §2 heuristic, len≥6 guard), writing a reviewable diff — never auto-committed,
  because judge/player notes are hand-owned editorial content. Expected yield: ~480 notes.
  Judge's `card-interaction-protocol` note and ROLE.md get one added line: "mint interaction
  notes with `--entities card:<a>,card:<b>`".
- **Regeneration safety (hard requirement, human decision §6.3):** no regenerating script may
  drop entities once present. Concretely: (1) generated notes (`card-*`, `kw-*`, lore) carry
  generator-EMITTED entities, so every rebuild reproduces them from the corpus — asserted by
  a build-twice/idempotence test; (2) generators continue to never touch hand-owned notes
  (backfilled judge/player entities live only in files the builders don't write), asserted by
  a test that runs `build`+`sync` over a fixture tree containing backfilled hand notes and
  diffs them byte-for-byte; (3) `build-card-vault.py check` and `keyword-sync.py check` fail
  if a generated note on disk is missing its expected `entities` line, so a stale/hand-stripped
  vault can't pass CI; (4) `brain.py entity-index` is derived purely from note frontmatter —
  regenerating it can never lose a declaration that exists in a note, and mint (`--entities`)
  re-mints over an existing slug preserve the field like every other frontmatter key.
- **TDD:** fab-cli's `test/` is TypeScript-only today; the Python builders have no harness.
  Add `test/scripts/` pytest (stdlib `unittest` acceptable, matching the scripts' stdlib-only
  stance) with corpus fixtures: failing tests first for (1) entity emission incl. pitch-variant
  merge + namesake disambiguation, (2) `check` staleness on entity drift, (3) backfill proposer
  precision on a fixture note set, (4) index regeneration idempotence. Plugin-side (this repo):
  extend `tests/section-brain.sh` (mint `--entities`, round-trip, entity-index build, symlink
  attribution) and `section-neural-view-*.sh` (entity edges in `/graph`, gradient config knob),
  gated by the standard `gate.sh` run.

## 5. Migration path

1. Plugin: `brain.py` mint/parse/render `entities` + `entity-index` command + tests. Backward
   compatible — notes without `entities` are simply absent from the index.
2. Plugin: neural-view `build_graph` entity edges + client edge type + gradient/config. View
   degrades gracefully for repos with no declarations (zero entity edges — today's render).
3. fab-cli: builders emit entities; regenerate card-vault (rides the already-planned slug
   consolidation regen); keyword-sync sync; commit as knowledge-update.
4. fab-cli: backfill proposer run → human (judge-hat) review → commit → `entity-index`.
5. Skills: ask-brain (+optionally ask-identity) index-consult step; brain skill docs.
6. Retro protocol: `entity-index` regen joins `directory` regen at retro time.

Rollback at any step = delete `entity-index.json` + ignore the frontmatter key; nothing else
depends on it.

## 6. Resolved decisions (human, 2026-07-12)

1. **`entity-index.json` is committed** (like `DIRECTORY.md`) — reviewable, and neural-view
   works on fresh clones. Regenerated by `entity-index`, the builders, and at retro time.
2. **Only `ask-brain` consults across the boundary.** Identities consult their own notes
   only. They can and should be AWARE that another identity may hold information (the index
   provides that awareness) and can ASK that identity for it explicitly (consult / an
   ask-identity call), then learn by minting into their own brain with provenance — but they
   never step over the boundary implicitly. §3.3 encodes this.
3. **Backfill lands as a single PR** (judge reviews the ix/ruling subset explicitly), and
   regeneration scripts must be proven — by tests — to never drop the backfilled or emitted
   entities (§4 "Regeneration safety").
