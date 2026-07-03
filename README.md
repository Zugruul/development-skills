# development-skills

A [Claude Code plugin marketplace](https://docs.claude.com/en/docs/claude-code/plugin-marketplaces) of development-workflow plugins.

## Install

```bash
claude plugin marketplace add /Users/vieiral/Development/development-skills
claude plugin install spec-workflow@development-skills
```

> Plugins are cached per version on install. After editing this repo, run
> `claude plugin marketplace update development-skills` (and bump the plugin `version`
> for a clean cache entry) so consumers pick up the changes.

Or per-repo (shared with everyone opening the repo) via `.claude/settings.json`:

```json
{
    "extraKnownMarketplaces": {
        "development-skills": {
            "source": { "source": "directory", "path": "/Users/vieiral/Development/development-skills" }
        }
    },
    "enabledPlugins": { "spec-workflow@development-skills": true }
}
```

## Plugins

### spec-workflow

Spec-driven autonomous build workflow. A repo declares its boards, specs, epics, guards, gate command, and conventions in a **versioned config** (`.claude/project.json`, schemaVersion 1 — schema in `plugins/spec-workflow/schemas/`); the plugin's skills and scripts read that config, so the same workflow drives any project.

| Skill | Purpose |
|---|---|
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
