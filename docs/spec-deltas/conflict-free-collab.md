---
task: 'conflict-free-collab'
spec: sw
sections: ["§8"]
---

## Conflict-free collaboration — sharded committed feeds + specs out of project.yaml

Every committed, growing artifact is sharded so no two writers ever append to the same file (multi-person repos can commit freely, merges never conflict):

- **Brain events**: `emit_event` writes to `.neural-network/brain-events/<writer>.jsonl` (writer = `$SPEC_WORKFLOW_WRITER` > git `user.email` localpart > `$USER`, sanitized to `[a-z0-9._-]`). The legacy single `brain-events.jsonl` is READ-ONLY history; `brain.py read_events(root)` (and the assistant digest's duplicated reader) merge legacy + all shards. §8.1's O_APPEND atomicity contract is unchanged per shard file.
- **Feedback feed**: `feedback.py emit` writes ONE NEW FILE per record — `feedbacks/feed/<ts-compact>-<writer>.yaml` — never appending to a shared file. `route` rewrites only the containing source file. `archive` moves a fully-routed shard byte-identically to `feedbacks/archive/<YYYY-MM>/<basename>` (per-file; no shared monthly append), while legacy `feed.yaml` documents keep the monthly `archive/<YYYY-MM>.yaml` append behavior. `pending`/`status`/`archived`/`migrate-qualify` operate over legacy + shards. New verb `migrate-shard` splits a legacy feed into per-doc shards (bytes preserved) and removes it. The duplicate-ts guard spans all sources.
- **Specs out of project.yaml**: project.yaml holds CONFIGURATION only; each spec's work-plan lives in `.neural-network/specs/<id>.yaml` (basename = spec id, template `templates/spec.example.yaml`). `config.py` merges the dir into `cfg.specs` (dir wins over inline); inline `specs:` is DEPRECATED but still read when no dir exists — `validate-config.py` prints a deprecation note and `preflight.sh --spec` suggests migrating before starting the next task.
- **neural-view compatibility**: unchanged — neural-view never read `brain-events.jsonl` directly; its config lookups go through the loader, which still presents the merged `cfg.specs` shape.
