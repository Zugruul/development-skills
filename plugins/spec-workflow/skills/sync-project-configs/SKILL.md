---
name: sync-project-configs
description: Discover every anchored repo (marked with .claude/.neural-network) under a scan base and bring its .claude/project.yaml up to this plugin's current config surface, via versioned sync rules. Dry-run by default. Use when the plugin's config surface has evolved (new methodology keys, path migrations) and consumer repos' project.yaml may have drifted, or the user asks to "sync configs" across repos.
allowed-tools: Bash
---

# Sync project configs

Run the deciding script -- it discovers repos, decides which sync rules apply, validates
before and after, and drives the git-safety protocol; this skill never edits YAML or git
state itself:

```bash
python3 "../../scripts/sync-configs.py" [--scan BASE] [--repo PATH] [--apply] [--feedback-value true|false]
```

- **Dry-run is the default.** Without `--apply`, the script prints per-repo rule decisions
  and diffs and changes nothing -- locally or remotely. Only pass `--apply` once you (or
  the user) have reviewed the dry-run output.
- `--scan BASE` overrides the scan base (default `~/Development`); every immediate child
  with a `.claude/.neural-network` marker is a candidate, except the plugin's own repo
  (it updates itself through the build loop, not this script).
- `--repo PATH` targets exactly one repo, bypassing discovery.
- `--feedback-value false` writes `feedback: false` instead of the default `true` for the
  `ensure-feedback-key` rule.

Report the script's output verbatim -- per-repo route (`main` / `worktree` / `skipped-invalid`
/ `no-op` / `dry-run`), rules applied, validation results, commit sha, push result -- and the
final `AGGREGATE` line.

## Rules
- Never touch a live checkout that is on a non-main branch or has a dirty tree -- the script
  routes those through a temporary worktree off `origin/<mainBranch>` instead.
- A repo whose config is already INVALID before any edit is skipped and reported, never
  edited.
- A repo skipped as `no-op` needed no rule -- do not re-run with `--apply` expecting a
  different result until the plugin's sync rules change.

## Sync rules currently applied
- `strip-schema-data-key` -- drops a legacy top-level `$schema:` data key (the modeline comment
  is the supported form).
- `ensure-feedback-key` -- adds `methodology.feedback` if missing (`--feedback-value` controls
  the written value, default `true`).
- `sw062-feedbacks-migration` -- moves `.claude/feedback/` to `.claude/feedbacks/` and drops the
  old `.gitignore` line.
- `ensure-peer-reviewer-identity` -- adds `delegation.identities.peer-reviewer` (the same
  default name/email templates as `agent-identities`' built-in default) ONLY when the target
  repo's own `.claude/settings.json` `enabledPlugins` map shows a truthy
  `peer-review@<marketplace>` key -- never forces the identity on a repo that doesn't have the
  plugin enabled. Inserts into an existing `delegation.identities` block if the repo already
  customizes one, else appends a fresh `delegation.identities` block.
- `ensure-serial-delivery` -- adds `methodology.serialDelivery: true` ONLY when the key is
  absent from the target's `methodology:` block. An existing explicit `true` or `false` is a
  choice the rule respects and leaves untouched -- no configurable value flag, unlike
  `ensure-feedback-key`.
