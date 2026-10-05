---
task: 'neural-network-layout'
spec: sw
sections: ["§5", "§7"]
---

## Repo layout — HARD CUTOVER to a root `.neural-network/` directory

Everywhere the spec (and SPEC-ASSISTANT/SPEC-MEMORY/SPEC-GRAPHIFY) says `.claude/project.yaml`, `.claude/project.local.yaml`, `.claude/identities/`, `.claude/feedbacks/`, `.claude/brain-events.jsonl`, or the `.claude/.neural-network` marker FILE, the path is now the root-level `.neural-network/` directory: `project.yaml`, `project.local.yaml`, `identities/`, `feedbacks/`, `brain-events.jsonl` inside it, and the DIRECTORY'S OWN EXISTENCE is the discovery marker (`isdir`, not `isfile`; an optional `marker` metadata file inside still parses under §6.2's permissive grammar and can never reject a repo). This is a hard cutover — the old locations are no longer read; `sync-project-configs`/`setup-project` migrate consumer repos. Ephemeral local state (board cache/queue, telemetry, gate-pass, CHECKPOINT, worktrees, ui-hub, neural-view/assistant state) STAYS under `.claude/` per the local-state manifest.

## Monorepo nesting — NEW (native folders only)

The root `.neural-network/project.yaml` is the source of truth. A NATIVE subfolder (no `.git` boundary of its own between it and the root — an externally cloned-in repo is never nested; its subtree is skipped) MAY carry its own `.neural-network/` holding per-package knowledge bases and a PARTIAL project.yaml. For work under that subtree, the nested fragment deep-merges OVER the root config (dicts per key, nested wins on scalars/lists); every omitted key is inherited. Surfaces: `config.py --for <repo-relative path>` (get/json), `config.py anchors`, `validate-config.py --fragment`. WHEN a nested fragment is consulted is the caller's choice of `--for` path (typically the task's touched paths); no board/picker semantics change.
