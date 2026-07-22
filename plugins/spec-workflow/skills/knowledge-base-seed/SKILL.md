---
name: knowledge-base-seed
description: Explores the current project (specs, backlogs, design docs, applied spec-deltas, READMEs/AGENTS.md/CLAUDE.md, script/source layout, git history, board epics from config) and seeds/updates a knowledge-graph identity brain (.claude/identities/knowledge/brain/) via kb-seed.sh, reusing brain.py's note/link machinery end to end. Use for '/knowledge-base-seed' — bootstrapping or refreshing a repo's knowledge brain so recall/explain/staleness and neural-view work on it for free, orchestrator-mediated like every brain.
allowed-tools: Bash
---

# Knowledge-graph seeding

`kb-seed.sh` = `bash "../../scripts/kb-seed.sh"`. Like every identity brain,
`knowledge` is orchestrator-mediated only — this skill runs `kb-seed.sh`,
never reads `.claude/identities/knowledge/brain/**` content directly.
`knowledge` is a brain-only role: no commit identity, no delegation entry,
nothing about its existence changes dev/reviewer/orchestrator behavior.

## Steps

1. Run the seeder from repo root:
   ```bash
   bash "../../scripts/kb-seed.sh" seed
   ```
   This explores (offline, no `gh` calls): each `specs[].specPath`/
   `backlogPath` in `.claude/project.yaml`, `specs[].epics` (board epics from
   config), `paths.designDir` markdown files, applied spec-deltas under
   `paths.specDeltaDir/applied/`, root `README.md`/`AGENTS.md`/`CLAUDE.md`,
   the top-level directory layout, and recent `git log` subjects (stdlib
   `git log` parsing only). Every note carries provenance frontmatter
   (`source: seed`, `seed-path`, `seed-commit`) so seeded notes are always
   distinguishable from retro-minted lessons.
2. Re-running is idempotent: unchanged sources produce a byte-identical
   no-op on `notes/`, `links.json`, and `DIRECTORY.md`. A changed source
   updates its note IN PLACE (same slug, bumped strength) — never a
   duplicate, never a delete.
3. If a run would update more than `methodology.shrinkGuardFraction` of the
   existing knowledge notes at once, the seeder refuses and writes nothing
   (GL-005 shrink guard, reused verbatim) — re-run with
   `bash "../../scripts/kb-seed.sh" seed --force` only after confirming the
   bulk change is intended.
4. Report the summary line (`seeded knowledge: N created, M updated, K
   unchanged, L new link(s)`) to the human. The seeded brain works with
   every existing brain command unmodified: `brain.sh recall knowledge ...`,
   `brain.sh explain knowledge <slug>`, `brain.sh status knowledge`, and
   neural-view's visualization.

## When to use

- Bootstrapping a repo's knowledge brain for the first time.
- Refreshing it after specs/backlogs/design docs/history have moved on —
  safe to run anytime; a no-op run costs nothing.

## Rules

- `knowledge` is brain-only — never grant it a commit identity or add it to
  `delegation.identities`.
- Never delete a seeded note; a source that disappears simply stops being
  re-touched, its note stays on disk.
- `--force` is a deliberate override, not a default habit — read the guard's
  "Would remove" list before using it.
