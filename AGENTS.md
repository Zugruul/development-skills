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

## Install and usage

See [`README.md`](README.md) for marketplace install/update instructions and the per-plugin skills tables.
