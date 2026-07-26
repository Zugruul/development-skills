---
name: changelog-generate
description: Regenerates the repo's CHANGELOG.md from git history, organized by release version and grouped by change type (features, fixes, etc.). Use when asked to generate, update, or refresh the changelog, to see what changed in a given release, or to summarize recent commits into release notes.
allowed-tools: Bash
---

# Generate the changelog

**This skill is READ-ONLY with respect to the repo's git history and the board** — the only file it ever writes is `CHANGELOG.md` itself (or wherever `--output` names).

```bash
python3 "../../scripts/changelog.py" generate [--repo <path>] [--output <path>] [--ref <ref>]
```

- `--repo <path>` defaults to the current repo's toplevel.
- `--output <path>` defaults to `<repo>/CHANGELOG.md`.
- `--ref <ref>` defaults to `HEAD` — the tip of the history to walk.

The script always does a **full, deterministic regeneration** of the entire file from `git log --first-parent <ref>` — there is no incremental "append since last run" mode, and no `--from`/`--to` range to pick. It reconstructs the plugin's version history by walking that first-parent chain and detecting, at every commit, the `version` recorded in `plugins/spec-workflow/.claude-plugin/plugin.json` (the value the #400 semver pipeline bumps in-commit at squash-merge time) — every commit is attributed to whichever version its own tree reports. Commits are then grouped into `## v<version> — <date>` sections (newest first, dated by that version's newest commit) and, within each, into fixed `### <Group>` subsections (Features/Fixes/Performance/Refactoring/Documentation/Tests/CI-Build/Chores/Other) by conventional-commit type. Workflow-process commits (`retro:`, `retro+feedback:`, `feedback:`, `brain:`, `config:`, and the changelog Action's own `chore(changelog):` commits) are dropped entirely — see `changelog.py`'s module docstring for the exact, load-bearing format spec.

Because regeneration is idempotent (the same history always produces byte-identical output), `.github/workflows/changelog.yml` runs this on every push to `main` and only commits when the result actually changed — that idempotence plus the `chore(changelog):` exclusion is what keeps the Action from looping on its own commits.

## Usage

Run the script against the repo root and show the human the resulting `CHANGELOG.md` (or a relevant slice of it, e.g. the newest version's section) — never write anywhere other than the default `CHANGELOG.md` path unless told otherwise via `--output`.
