# development-skills

Plugins that teach coding agents to work in [Herdr](https://herdr.dev) and to design UIs, for [Claude Code](https://docs.claude.com/en/docs/claude-code/plugin-marketplaces), Codex and [OpenCode](https://opencode.ai): a marketplace for the first two, and an installer script for OpenCode.

## Plugins

| Plugin | What it is | Needs |
| --- | --- | --- |
| [`herdr`](plugins/herdr/README.md) | Worktrees, agents, prompts, listening and status in Herdr | `herdr`, `bash`, `jq`, `git` |
| [`herdr-graph-engineering`](plugins/herdr-graph-engineering/README.md) | One orchestrator chat; each idea is a lane running a small graph to its definition of done | `herdr` plugin, `jq`, `yq`, `git` |
| [`herdr-simple-orchestrate`](plugins/herdr-simple-orchestrate/README.md) | Deprecated: the old orchestrator role and multi-PR code review | `herdr` plugin |
| [`ui-design`](plugins/ui-design/README.md) | Mock UI options and let the human decide | `bash`, `jq`, `git`, `socat` |

### Archived plugins

`spec-workflow`, `remote-compute`, `peer-review`, `scaffold-project` and `herdr-development-skills` are **archived**. They are no longer in this marketplace. They have their own marketplace in [`archived/`](archived/README.md), installed from a clone:

```bash
git clone https://github.com/Zugruul/development-skills.git
claude plugin marketplace add ./development-skills/archived
claude plugin install spec-workflow@development-skills-archived
```

**Had one of them installed from here?** This is a breaking change: once your copy of this marketplace updates, Claude Code can no longer load it. Follow [Moving an existing install](archived/README.md#moving-an-existing-install).

## Client support

| Plugin | Claude Code | Codex | OpenCode |
| --- | --- | --- | --- |
| `herdr` | full | full | full (skill names without the plugin prefix) |
| `herdr-graph-engineering` | full | works; no hook for the client's own error (screen instead), no waiter (the Herdr plugin wakes it), hooks need your trust | full, through the plugin's OpenCode plugin |
| `herdr-simple-orchestrate` | full | full (install `herdr` too) | full (`orchestrate` is named `herdr-simple-orchestrate-orchestrate`) |
| `ui-design` | full | works; the agent does not wake by itself on your pick | works; the same as Codex, and no resume command on the page |

"Full" means that every feature has a way to work in that client; no client was run against a live Herdr. Each plugin's README has a `## Clients` section with the detail and what was tested. Versions used: Claude Code 2.1.332, Codex 0.165.0, OpenCode 1.19.4.

## Install

### Claude Code

```bash
claude plugin marketplace add Zugruul/development-skills
claude plugin install herdr@development-skills
```

For another plugin, substitute its name. Or per repository (shared with everyone opening it) via `.claude/settings.json`:

```json
{
    "extraKnownMarketplaces": {
        "development-skills": {
            "source": { "source": "github", "repo": "Zugruul/development-skills" }
        }
    },
    "enabledPlugins": { "herdr@development-skills": true }
}
```

### Codex

```bash
codex plugin marketplace add Zugruul/development-skills
```

Restart the ChatGPT desktop app, open the Plugins Directory, select **Development Skills**, and install the plugin or plugins you need. Start a new chat after installation so Codex loads their skills. For a local checkout, run `codex plugin marketplace add .` from the repository root instead.

In the Codex CLI, install each plugin with `codex plugin add <plugin>@development-skills`. Codex does not install a plugin's dependencies: for `herdr-graph-engineering` or `herdr-simple-orchestrate`, install `herdr` too. After installing or updating `herdr-graph-engineering`, open `/hooks` and trust its hooks.

Before updating, confirm `codex plugin marketplace list` includes
`development-skills` in the same runtime/profile as the desktop's active skill
path. Then run `codex plugin marketplace upgrade development-skills`, verify
the installed files changed, and restart the desktop/start a new chat. An empty
CLI listing does not prove the desktop has no plugin; resolve discrepancies
before adding or reinstalling anything. Marketplace installs keep the packaged
skills together with their scripts, references, and templates.
`install-skills.sh codex` is an alternative for linking raw skill folders into
a project's `.agents/skills/`; use one installation method per skill to avoid duplicates.

### OpenCode

OpenCode has no plugin marketplace for these. Install from a clone:

```bash
git clone https://github.com/Zugruul/development-skills.git
./development-skills/install-skills.sh opencode --global
```

This links the skills of every maintained plugin and the OpenCode plugin of `herdr-graph-engineering` into `~/.config/opencode/` (`OPENCODE_CONFIG_DIR` and `XDG_CONFIG_HOME` are honoured). To update, run `git pull` in the clone, then the installer again, and restart OpenCode. Without `--global` it installs into the current project only.

OpenCode names a skill without its plugin (`herdr:worktree` is `worktree`). It also reads `.claude/skills` and `.agents/skills`, so two skills never get the same name: the second `orchestrate` is installed as `herdr-simple-orchestrate-orchestrate`.

### Skill directories (all three clients)

The same installer also serves Claude Code and Codex, instead of their marketplaces:

```bash
./install-skills.sh all        # or: claude | opencode | codex; add --global for your user folders
```

| Client | In a project | With `--global` | Marketplace alternative |
|-|-|-|-|
| Claude Code | `.claude/skills/` | `~/.claude/skills/` | `.claude-plugin/marketplace.json` (also brings the hooks) |
| Codex | `.agents/skills/` | `~/.agents/skills/` | `.agents/plugins/marketplace.json` (also brings the hooks) |
| OpenCode | `.opencode/skills/` and `.opencode/plugins/` | `~/.config/opencode/` | none |

It links, never copies, so edits are live (the one exception is the small pointer file for a duplicate name). Linked skill folders carry no hooks for Claude Code or Codex: use the marketplace for `herdr-graph-engineering` there. Use one way per client, not both. Set `DEV_SKILLS_PROJECT_ROOT` to target another project.

## Update

Refresh the marketplace listing, then update the installed plugin you need:

```bash
claude plugin marketplace update development-skills
claude plugin update herdr@development-skills
```

In Claude Code's `/plugin` Installed view, **Update now** updates one plugin. Verify the installed copy, then reload plugins or start a new session. For Codex and OpenCode, see their install sections above.

## Plugin details

### herdr

Skills that teach an agent to use [Herdr](https://herdr.dev), the terminal
workspace manager for AI coding agents: start worktrees and agents, prompt them
without duplicates, listen to their work, and see what is running. It only
teaches Herdr: no workflow of its own and no knowledge of other plugins. Thin
over the `herdr` CLI, with three bash scripts for what the CLI cannot do in one
call. See [herdr](plugins/herdr/README.md).

| Skill | Purpose |
|---|---|
| `worktree` | Start a Herdr worktree after read-only checks and the user's approval, optionally with agents on it, each with a first prompt |
| `agent` | Start an agent in an existing pane, retrying while the pane is busy, then send its first prompt |
| `prompt` | Send a follow-up prompt with `herdr agent prompt --wait`, or relay the user's answer to a blocked agent; never submits the same text twice |
| `listen` | Report what agents are doing, wait until one blocks or finishes, and surface its question, asking which agent or tab when unclear |
| `status` | Read-only lists of live agents and the repository's open worktrees |

```bash
claude plugin install herdr@development-skills
```

### herdr-graph-engineering

Graph engineering on Herdr, kept thin. One orchestrator chat takes your ideas;
each becomes a lane (its own worktree) running a small graph from a pattern
(`solo`: implementer then a tests gate with bounded retries; `pair`: the same
plus a second-opinion reviewer; `fast`: urgent fixes, on request, the draft pull
request opens before the tests gate; `investigate`: a read-only report). Scripts decide what is ready and record results in one lane
file per lane; the orchestrator checks evidence, opens a draft pull request when
a lane is done, and asks you only when a lane needs you. **Requires the herdr
plugin**, `jq`, `yq` and `git`. See
[herdr-graph-engineering](plugins/herdr-graph-engineering/README.md).

| Skill | Purpose |
|---|---|
| `orchestrate` | The one chat: route ideas into lanes and run them until their definition of done |
| `display` | Opens or closes the Herdr graph panel next to the orchestrator (refresh, interval toggle, jump, answer), or prints the picture as text |
| `concurrency` | Guidance for running many lanes at once; no limit by default, a cap only when you ask |
| `afk` | While on, the orchestrator decides the safe things itself, records each and shows the list when you return |
| `auto-merge` | While on (off by default), the orchestrator may merge a lane's pull request after its gate and reviews pass |
| `feedback-loop` | While on (off by default), lanes' lessons become improvement pull requests, never with task details |

```bash
claude plugin install herdr-graph-engineering@development-skills
```

### herdr-simple-orchestrate (deprecated)

The old way of orchestrating agents in Herdr, moved out of `herdr`: the
orchestrator role and an orchestrated code review of related pull requests.
Kept so existing setups keep working. **Requires the herdr plugin.** See
[herdr-simple-orchestrate](plugins/herdr-simple-orchestrate/README.md).

| Skill | Purpose |
|---|---|
| `orchestrate` | Take the orchestrator role, load the herdr skills, and report on demand (`NEEDS YOU`, `WORKING`, `DONE`) |
| `orchestrate-code-reviews` | Orchestrate a code review of a group of related pull requests: one reviewer agent per worktree plus a cross-PR checker draft, one agent per pull request posts a single COMMENT review, then the orchestrator puts a verified summary into that review's body |

```bash
claude plugin install herdr-simple-orchestrate@development-skills
```

### ui-design

![](./docs/ui-mode-example.png)
![](./docs/ui-mode-annotate.png)
![](./docs/ui-mode-accessibility.png)

Mock a UI before it is built and let the human decide. The agent mocks 2–4
genuinely different options at the target's real size and serves them on a
local decision hub; the human picks, favorites, ticks aspects or annotates
elements, and the answer comes straight back. Every page passes an
accessibility audit in both themes (WCAG contrast, real semantics, target size,
input purpose, axe-core), carries a `data-testid` on every control, and is
translated when asked. Standalone: no workflow, tracker or other plugin; other
skills call it by name. Needs `bash`, `jq`, `git` and `socat`. See
[ui-design](plugins/ui-design/README.md).

| Skill | Purpose |
|---|---|
| `ui-mode` | Show or toggle Iterative UI mode (the human decides UIs, or the agent does) |
| `ui-options` | Mock the options, gate them, ask on the hub, iterate until the human commits, record the pick |

```bash
claude plugin install ui-design@development-skills
```

## Working on this repository

```bash
bash plugins/herdr/tests/run-tests.sh                    # hermetic: runs against a stub herdr, no Herdr install needed
bash plugins/herdr-graph-engineering/tests/run-tests.sh
bash plugins/herdr-simple-orchestrate/tests/run-tests.sh
bash plugins/ui-design/tests/run-tests.sh                # hermetic: stub socat, the hub handler driven on stdin
bash .github/tests/run-tests.sh                          # install-skills.sh and check-marketplaces.sh
bash .github/scripts/check-marketplaces.sh               # both marketplaces, root and archived
```

To try your changes, point the marketplace at your clone instead. With a `directory` source, skill edits reach new sessions immediately (no version bump):

```bash
claude plugin marketplace remove development-skills
claude plugin marketplace add /path/to/development-skills
```

Removing a marketplace uninstalls the plugins installed from it, so reinstall the ones you need.

The rules for agents and contributors are in [`AGENTS.md`](AGENTS.md), for Claude Code, Codex and OpenCode; [`CLAUDE.md`](CLAUDE.md) points to it. [`CHANGELOG.md`](CHANGELOG.md) is generated on `main`.
