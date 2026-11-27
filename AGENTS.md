# AGENTS.md

This repo is [Zugruul/development-skills](https://github.com/Zugruul/development-skills), a Claude Code and Codex plugin marketplace. This file is the canonical instruction file for both hosts; `CLAUDE.md` only points here.

## Layout

| Path | What is there |
| --- | --- |
| `plugins/<name>/` | The maintained plugins, listed by `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json` |
| `archived/` | Archived plugins, a marketplace of their own. Read [`archived/AGENTS.md`](archived/AGENTS.md) before touching anything in it |
| `docs/`, `SPEC*.md` | Specs, backlogs, design notes and history |
| `.github/` | CI, the release workflows and `scripts/check-marketplaces.sh` |

Specs and history in `docs/` and `SPEC*.md` predate the archive: read a `plugins/<name>/` path of an archived plugin in them as `archived/plugins/<name>/`.

## Plugins

| Plugin | What it is | Needs |
| --- | --- | --- |
| [`herdr`](plugins/herdr/README.md) | Teaches an agent to use [Herdr](https://herdr.dev): worktrees, agents, prompts, listening, status. Only Herdr, no workflow of its own, no knowledge of other plugins. | `herdr`, `bash`, `jq`, `git` |
| [`herdr-graph-engineering`](plugins/herdr-graph-engineering/README.md) | Graph engineering on `herdr`: one orchestrator chat, each idea a lane running a small graph from a pattern until its definition of done. | `herdr` plugin, `jq`, `yq`, `git` |
| [`ui-design`](plugins/ui-design/README.md) | Mocks UI options before implementation and lets the human decide on a local hub; accessibility in both themes, test ids, i18n. No workflow, no knowledge of other plugins. | `bash`, `jq`, `git`, `socat` |
| [`herdr-simple-orchestrate`](plugins/herdr-simple-orchestrate/README.md) | **Deprecated**: the old orchestrator role and multi-PR code review, moved out of `herdr`. Change it only to keep it working. | `herdr` plugin |

Archived: `spec-workflow`, `remote-compute`, `peer-review`, `scaffold-project`, `herdr-development-skills`. No maintained plugin depends on one or reaches into `archived/`.

## Rules for every plugin

- **One plugin, one job.** A plugin carries the scripts it needs and nothing else. It never reaches into another plugin's folder: installed plugins live in versioned folders, so a path into another plugin breaks. It uses another plugin through that plugin's skills, by name (`herdr:worktree`), and declares the dependency in `.claude-plugin/plugin.json` (`"dependencies"`).
- **No Python in maintained plugins.** Scripts are `bash` (3.2 or later, so the macOS default works; WSL on Windows) with `jq` for JSON. Shared helpers sit in a flat `scripts/src/` folder, one level deep.
- **Only scripts that are really needed.** When the tool's own CLI does a step in one call, the skill calls the CLI directly. A script exists for a wait, a retry or a safety check the CLI cannot do.
- **Tests are hermetic.** Each plugin has `tests/run-tests.sh`, sourcing `section-*.sh` files, with stubs for external binaries. No live session, no network.
- **Two manifests, same version.** `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json`, with the same version, and an entry in both `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json`. Bump the version when behaviour changes.
- **Skill descriptions** have no angle brackets (Codex rejects them) and name the triggers a user would type.
- No AI attribution or `Co-Authored-By` lines in commits, pull requests or files.

## Validating a change

Run the checks of every plugin you touched, green, before calling the work done:

```bash
bash plugins/herdr/tests/run-tests.sh
bash plugins/herdr-graph-engineering/tests/run-tests.sh
bash plugins/herdr-simple-orchestrate/tests/run-tests.sh
bash plugins/ui-design/tests/run-tests.sh
shellcheck -x .github/scripts/*.sh
shellcheck -x plugins/herdr/scripts/*.sh plugins/herdr/scripts/src/*.sh plugins/herdr/tests/*.sh plugins/herdr/tests/fixtures/stub-herdr/herdr
shellcheck -x plugins/herdr-graph-engineering/scripts/*.sh plugins/herdr-graph-engineering/scripts/src/*.sh plugins/herdr-graph-engineering/tests/*.sh plugins/herdr-graph-engineering/tests/fixtures/stub-herdr/herdr
shellcheck -x plugins/ui-design/scripts/*.sh plugins/ui-design/scripts/src/*.sh plugins/ui-design/tests/*.sh plugins/ui-design/tests/fixtures/stub-socat/socat
claude plugin validate . && claude plugin validate plugins/herdr && claude plugin validate plugins/herdr-graph-engineering && claude plugin validate plugins/herdr-simple-orchestrate && claude plugin validate plugins/ui-design
bash .github/scripts/check-marketplaces.sh
```

A change under `archived/` follows [`archived/AGENTS.md`](archived/AGENTS.md).

## Releases

On a push to `main`, `.github/workflows/semver.yml` and `changelog.yml` run scripts of the archived `spec-workflow`: a `feat`, `fix`, `perf`, `refactor` or breaking commit that did not change spec-workflow's version bumps it (whichever plugin the commit touched), and `CHANGELOG.md` is regenerated with those versions as its headings.

## Adding a plugin

1. `plugins/<name>/` with `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `README.md`, `skills/<skill>/SKILL.md`, `tests/run-tests.sh`, and `scripts/` only if needed.
2. Register it in both marketplace files.
3. Add it to the tables in this file and in the root `README.md`.
