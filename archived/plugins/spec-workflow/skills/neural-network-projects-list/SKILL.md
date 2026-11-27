---
name: neural-network-projects-list
description: List local repositories anchored with .neural-network and summarize their config, methodology toggles, configured boards and validation errors. Use for a read-only project inventory or to see which local projects participate in spec-workflow.
allowed-tools: Bash
---

# List local projects

Resolve `../../scripts/projects-list.py` relative to this installed `SKILL.md`.
Use that absolute script path, quoted for spaces, while keeping the consumer
working directory as the command's cwd. The plugin root comes from the skill's
location, never from the consumer cwd or a required host environment variable.

Run the shared engine with the arguments requested in the user's message:

```bash
python3 "/absolute/plugin-root/scripts/projects-list.py" [--scan BASE] [--root DIR] [--json]
```

Replace the example absolute path with the resolved installed path; bracketed
arguments are optional, not literal shell syntax. Both hosts use this engine.
Claude discovers `/spec-workflow:neural-network-projects-list` automatically;
in Codex, select the installed `neural-network-projects-list` skill or request
its described operation. No host-specific argument placeholder is required.

- The scan defaults to `~/Development` and considers only immediate children
  carrying a `.neural-network/` directory. Symlink aliases are deduplicated.
- The current Git root (or cwd outside Git) is always included. `--root DIR`
  explicitly selects that current repo, including a repo with no marker/config.
- Each row shows path, project name, detected schema version, `maxInProgress`,
  `autoMerge`, `serialDelivery`, feedback enabled, `iterativeUI`, every configured
  board's provider/number, and `OK` or `INVALID` with the first validator error.
  Missing settings are `unspecified` (JSON null); malformed values are marked.
- Config selection uses each repo's canonical YAML/YML/legacy JSON paths and
  shared loader, ignoring ambient `PROJECT_CONFIG`. Missing/integer schema
  versions are detected as `1.0.0` before legacy normalization.

Report the compact table, retaining invalid rows and their diagnostics. Use
`--json` when structured rows are needed. Invalid rows do not fail the inventory.
Do not run the config-rejecting workflow preflight before this command: invalid
configs are part of its output. This operation reads local files only; it never
creates anchors, edits configs, writes caches or fetches live board status.
