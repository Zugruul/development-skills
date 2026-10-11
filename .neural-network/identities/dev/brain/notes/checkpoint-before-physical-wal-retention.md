---
tags: [sqlite, retention, testing]
paths: ["plugins/spec-workflow/scripts/assistant/observability.py"]
strength: 1
source: "Local #510/#534 repair and #507 integration review"
confidence: direct
graduated: false
created: 2026-10-11
last-touched: 2026-10-11
---

## Measure Before Deleting
- An open SQLite WAL database can have compact logical pages but a stale main-file size after `VACUUM`.
- Before physical-size retention deletes another chunk, require a successful checkpoint that makes the measurement current.
- If a reader pins WAL history, defer size deletion; more deletion cannot reclaim that pinned storage.

## Regression Evidence
- Disable autocheckpoint, keep the writer open, and hold an independent reader snapshot.
- Assert the exact nonempty newest suffix, physical reclamation, writer reuse, and reopen durability.
