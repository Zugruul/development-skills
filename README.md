# development-skills

A [Claude Code plugin marketplace](https://docs.claude.com/en/docs/claude-code/plugin-marketplaces) of development-workflow plugins.

## Install

```bash
claude plugin marketplace add event-sorcerer/development-skills
claude plugin install spec-workflow@development-skills
```

Or per-repo (shared with everyone opening the repo) via `.claude/settings.json`:

```json
{
    "extraKnownMarketplaces": {
        "development-skills": {
            "source": { "source": "github", "repo": "event-sorcerer/development-skills" }
        }
    },
    "enabledPlugins": { "spec-workflow@development-skills": true }
}
```

## Update

Pull the latest skills from this repo at any time:

```bash
claude plugin marketplace update development-skills
```

or open `/plugin` in Claude Code and use **Update now** on the `development-skills` marketplace.

## Local development

To hack on the skills, point the marketplace at your clone instead — with a
`directory` source, skill edits reach new sessions immediately (no version bump):

```bash
claude plugin marketplace remove development-skills
claude plugin marketplace add /path/to/development-skills
```

## Plugins

### spec-workflow

Spec-driven autonomous build workflow. A repo declares its boards, specs, epics, guards, gate command, and conventions in a **versioned config** (`.claude/project.json`, schemaVersion 1 — schema in `plugins/spec-workflow/schemas/`); the plugin's skills and scripts read that config, so the same workflow drives any project.

| Skill | Purpose |
|---|---|
| `craft-spec` | Assisted spec creation: interview → draft → review → backlog |
| `setup-project` | Bootstrap a repo: config, GitHub Project board, validation |
| `seed-board` | Create issues + board items from a spec's backlog (idempotent) |
| `board` | All board reads/writes (single script, no hardcoded ids) |
| `next-task` | Prioritized + sequenced + guarded pick; reads human comments |
| `implement-task` | One task via TDD, delegated to a dev subagent with a what/how/why brief |
| `gate` | The project's single green-before-advance quality command |
| `build-next` | One full loop iteration — drive with `/loop /spec-workflow:build-next` |
| `checkpoint` | Pause/resume the loop via a local flag file |
| `handoff` | Session/pause handoff document |
| `dev-up` | Bring up the project's dev stack for QA |

Humans steer the loop by commenting on task issues: `next-task`/`implement-task` read every comment before starting, fold accepted changes into the issue's acceptance criteria, and reply on the issue.
