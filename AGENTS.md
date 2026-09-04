# AGENTS.md

This repo is [Zugruul/development-skills](https://github.com/Zugruul/development-skills), a Claude Code plugin marketplace: `spec-workflow`, `scaffold-project`, and `peer-review` ship from `plugins/`, installable via `claude plugin marketplace add`. `spec-workflow` — the autonomous build-loop plugin — develops *this very repo*, dogfood-style.

## You may be the loop itself

That dogfooding isn't incidental: this repo is built by the `spec-workflow` plugin it ships, autonomously, one board task at a time, via `/spec-workflow:build-next`. If you were invoked to implement a task here, there is a real chance you *are* an instance of that same loop — a dev/reviewer/orchestrator identity working a spec-driven task off the GitHub Project board. Behave accordingly: strict TDD (a failing test commits before the implementation that turns it green), and don't hand-wave the gate below.

## Where the contract lives

- [`SPEC.md`](SPEC.md) — spec-workflow's own contract (the plugin most of this repo's work targets).
- [`SPEC-CODEX-COMPAT.md`](SPEC-CODEX-COMPAT.md) — the dual-host (Claude Code + Codex) compatibility spec that this file itself exists to satisfy (§6.5).
- [`docs/BACKLOG-CODEX-COMPAT.md`](docs/BACKLOG-CODEX-COMPAT.md) — the task backlog for that compatibility work.
- [`.neural-network/project.yaml`](.neural-network/project.yaml) — machine-readable config: boards, specs, epics, invariants, and the gate command below.

## Validating a change

The single command that proves a change is correct in this repo (`.neural-network/project.yaml`'s `commands.gate`, quoted verbatim):

```
bash plugins/spec-workflow/tests/run-tests.sh && shellcheck -x plugins/spec-workflow/scripts/*.sh plugins/spec-workflow/scripts/lib/*.sh plugins/spec-workflow/tests/*.sh && claude plugin validate plugins/spec-workflow
```

Run it green before considering any task done.

## Schema versioning

Every schema'd file this repo owns (a consumer repo's `.neural-network/project.yaml`, its `specs/<id>.yaml` files, and any future config-family file) carries a `schemaVersion` as a **semver string** — current: `"2.0.0"`. A missing field, or the legacy integers (`1` json era, `2` pre-cutover yaml era), all read as **`1.0.0`** (`config.py schema_semver()` / the `schema-version` CLI verb are the one detection path).

Maintaining it — any schema-breaking change MUST, in the same PR:

1. Bump `SCHEMA_SEMVER` in `plugins/spec-workflow/scripts/config.py` (major bump for breaking changes).
2. Add a `## <old> → <new>` chapter to `plugins/spec-workflow/skills/migrate-version/references/migrations.md` with **idempotent** steps a consumer repo follows to migrate (the `migrate-version` skill applies chapters in order and verifies after each).
3. Update `validate-config.py`'s accepted versions and `schemas/project-config.schema.json`'s `schemaVersion` description, plus any deprecation note text.
4. Never break reading of the previous version silently: old versions stay detectable and the registry says how to leave them.

## Install and usage

See [`README.md`](README.md) for marketplace install/update instructions and the per-plugin skills tables.
