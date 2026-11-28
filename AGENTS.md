# AGENTS.md

This repo is [Zugruul/development-skills](https://github.com/Zugruul/development-skills), a plugin marketplace for Claude Code and Codex whose plugins also work in OpenCode. This file is the canonical instruction file for all three clients: Codex and OpenCode read it, and `CLAUDE.md` only points here (Claude Code).

## Layout

| Path | What is there |
| --- | --- |
| `plugins/<name>/` | The maintained plugins, listed by `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json` |
| `archived/` | Archived plugins, a marketplace of their own. Read [`archived/AGENTS.md`](archived/AGENTS.md) before touching anything in it |
| `docs/`, `SPEC*.md` | Specs, backlogs, design notes and history |
| `install-skills.sh` | Links the maintained plugins' skills (and OpenCode plugins) into a client's folders: OpenCode's install, and a second way for Claude Code and Codex |
| `.github/` | CI, the release workflows, `scripts/check-marketplaces.sh`, and `tests/` for it and `install-skills.sh` |

Specs and history in `docs/` and `SPEC*.md` predate the archive: read a `plugins/<name>/` path of an archived plugin in them as `archived/plugins/<name>/`.

## Plugins

| Plugin | What it is | Needs |
| --- | --- | --- |
| [`herdr`](plugins/herdr/README.md) | Teaches an agent to use [Herdr](https://herdr.dev): worktrees, agents, prompts, listening, status. Only Herdr, no workflow of its own, no knowledge of other plugins. | `herdr`, `bash`, `jq`, `git` |
| [`herdr-graph-engineering`](plugins/herdr-graph-engineering/README.md) | Graph engineering on `herdr`: one orchestrator chat, each idea a lane running a small graph from a pattern until its definition of done. | `herdr` plugin, `jq`, `yq`, `git`; `gh` for pull requests |
| [`ui-design`](plugins/ui-design/README.md) | Mocks UI options before implementation and lets the human decide on a local hub; accessibility in both themes, test ids, i18n. No workflow, no knowledge of other plugins. | `bash`, `jq`, `git`, `socat` |
| [`herdr-simple-orchestrate`](plugins/herdr-simple-orchestrate/README.md) | **Deprecated**: the old orchestrator role and multi-PR code review, moved out of `herdr`. Change it only to keep it working. | `herdr` plugin |

Archived: `spec-workflow`, `remote-compute`, `peer-review`, `scaffold-project`, `herdr-development-skills`. No maintained plugin depends on one or reaches into `archived/`.

## Three clients: Claude Code, Codex and OpenCode

**Every plugin, skill, script and hook must work with Claude Code, Codex and OpenCode.**

- A change states how each of the three is covered and how it was tested (a hermetic test, a run of the real client with isolated config folders, or "not run" with the reason). Put this in the pull request.
- A feature that only one client has needs a working fallback for the others, written down in the plugin's README. Never drop a client without saying so.
- Check a client's behaviour in its own documentation or with the real command. A fake client in a test only does what you assumed: a real OpenCode found a deadlock that the fake one did not.
- Never run such a check against your own `~/.claude`, `~/.codex` or OpenCode config, or against a live Herdr. Point `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `HOME` and the `XDG_*` folders into a scratch folder, and put a stub `herdr` on `PATH`.

| Subject | Claude Code | Codex | OpenCode |
| --- | --- | --- | --- |
| Install | `.claude-plugin/` marketplace | `.agents/plugins/` marketplace | `./install-skills.sh opencode [--global]` |
| Manifest | `.claude-plugin/plugin.json` | `.codex-plugin/plugin.json` | none |
| Plugin dependencies | installed with the plugin | not installed: the README says to install them | the installer installs every plugin |
| Skill name | `plugin:skill` | `plugin:skill` | the frontmatter `name` alone, which must be the folder's name and unique; the installer renames a duplicate |
| Hooks | `hooks/hooks.json` | `hooks/hooks.json`, after the user trusts them; no `StopFailure`, no `asyncRewake` | `opencode/<name>.js`, a plugin that calls the same scripts |
| Skill argument | `$ARGUMENTS` | left as written: the skill says to read the user's message | the same as Codex |
| Question to the user | `AskUserQuestion` | `request_user_input` only where offered: plain text fallback | `question` |

In a skill: say what to do without a client's tool, take `../../` paths from the real folder of a linked skill, and give OpenCode's name for another plugin's skill. `tests/section-clients.sh` in each plugin and `check-marketplaces.sh` check what can be checked cheaply.

## Rules for every plugin

- **One plugin, one job.** A plugin carries the scripts it needs and nothing else. It never reaches into another plugin's folder: installed plugins live in versioned folders, so a path into another plugin breaks. It uses another plugin through that plugin's skills, by name (`herdr:worktree`), and declares the dependency in `.claude-plugin/plugin.json` (`"dependencies"`).
- **No Python in maintained plugins.** Scripts are `bash` (3.2 or later, so the macOS default works; WSL on Windows) with `jq` for JSON. Shared helpers sit in a flat `scripts/src/` folder, one level deep. The one exception is an OpenCode plugin (`opencode/*.js`), because OpenCode loads only JavaScript: keep it a thin adapter that calls the bash scripts and holds no rule of its own. Its tests need `node`.
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
bash .github/tests/run-tests.sh
shellcheck -x .github/scripts/*.sh .github/tests/*.sh install-skills.sh
shellcheck -x plugins/herdr/scripts/*.sh plugins/herdr/scripts/src/*.sh plugins/herdr/tests/*.sh plugins/herdr/tests/fixtures/stub-herdr/herdr
shellcheck -x plugins/herdr-graph-engineering/scripts/*.sh plugins/herdr-graph-engineering/scripts/src/*.sh plugins/herdr-graph-engineering/tests/*.sh plugins/herdr-graph-engineering/tests/fixtures/stub-herdr/herdr
shellcheck -x plugins/ui-design/scripts/*.sh plugins/ui-design/scripts/src/*.sh plugins/ui-design/tests/*.sh plugins/ui-design/tests/fixtures/stub-socat/socat
claude plugin validate . && claude plugin validate plugins/herdr && claude plugin validate plugins/herdr-graph-engineering && claude plugin validate plugins/herdr-simple-orchestrate && claude plugin validate plugins/ui-design
bash .github/scripts/check-marketplaces.sh
```

Add `plugins/herdr-simple-orchestrate/scripts/*.sh plugins/herdr-simple-orchestrate/scripts/src/*.sh plugins/herdr-simple-orchestrate/tests/*.sh` to `shellcheck -x` when you change that plugin. `check-marketplaces.sh` also checks, for each maintained plugin: equal versions in both manifests, skill names and descriptions that all three clients accept, an OpenCode plugin beside any `hooks.json`, and a `## Clients` section in its README that names all three.

A change under `archived/` follows [`archived/AGENTS.md`](archived/AGENTS.md).

## Releases

On a push to `main`, `.github/workflows/semver.yml` and `changelog.yml` run scripts of the archived `spec-workflow`: a `feat`, `fix`, `perf`, `refactor` or breaking commit that did not change spec-workflow's version bumps it (whichever plugin the commit touched), and `CHANGELOG.md` is regenerated with those versions as its headings.

## Adding a plugin

1. `plugins/<name>/` with `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `README.md` with a `## Clients` section, `skills/<skill>/SKILL.md`, `tests/run-tests.sh` with a `section-clients.sh` (copy one), and `scripts/` only if needed. Hooks need an `opencode/*.js` beside them.
2. Register it in both marketplace files.
3. Add it to the tables in this file and in the root `README.md`.
