# Migration registry — one chapter per version hop

Chapters are applied IN ORDER by the `migrate-version` skill. Every step must be idempotent (safe to re-run after a partial migration). Newest chapter last.

## 1.0.0 → 2.0.0

The `.neural-network` cutover: config + knowledge move out of `.claude/` into a root `.neural-network/` directory (whose existence is also the discovery marker), the work-plan leaves project.yaml, and every committed growing file becomes conflict-free sharded.

1. **Create the home**: `mkdir -p .neural-network` at the repo root.
2. **Move config + knowledge** (use `git mv` for tracked files so history follows):
   - `.claude/project.yaml` → `.neural-network/project.yaml` (same for `project.local.yaml`, gitignored — plain `mv`)
   - `.claude/identities/` → `.neural-network/identities/`
   - `.claude/feedbacks/` → `.neural-network/feedbacks/`
   - `.claude/brain-events.jsonl` → `.neural-network/brain-events/<writer>.jsonl` — attribute the legacy events to their author (writer id = git email localpart, sanitized); or leave it at `.neural-network/brain-events.jsonl`, which stays readable as history.
   - Delete the old `.claude/.neural-network` marker FILE — the directory is the marker now.
   - Ephemeral local state (board cache/queue, telemetry, gate-pass, CHECKPOINT, worktrees…) STAYS in `.claude/`.
3. **Split the specs out**: move each entry of project.yaml's inline `specs:` list to its own `.neural-network/specs/<id>.yaml` (the basename is the spec id; template `templates/spec.example.yaml`), then delete the inline `specs:` section. The loader merges the dir back into `cfg.specs`, so consumers are unaffected.
4. **Shard the feedback feed**: `python3 scripts/feedback.py <root> migrate-shard` — splits a legacy `feedbacks/feed.yaml` into per-document shards under `feedbacks/feed/legacy/` and removes the legacy file. Monthly archive files stay as readable history.
5. **Stamp the version**: set `schemaVersion: "2.0.0"` (the string) in `.neural-network/project.yaml`.
6. **Reconcile gitignore**: `bash scripts/gitignore-sync.sh` (updates the managed block to the 2.0.0 paths).
7. **Verify**: `validate-config.py` VALID with no deprecation notes; `preflight.sh --spec` clean; if neural-view is running, its settings **↻ Refresh repos** button picks the repo up without a restart.
