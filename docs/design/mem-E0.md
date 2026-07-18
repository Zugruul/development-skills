# Design — mem/E0: Feedback lifecycle
Grounded in: SPEC-MEMORY.md §6 (§6.1-§6.6)

## Components (this task, MEM-002, covers only §6.3)
`plugins/spec-workflow/scripts/feedback.py` gains a new `archived [--since YYYY-MM]` subcommand, alongside the existing `emit`/`pending`/`route`/`status`/`migrate-qualify`/`archive` verbs.

## Already built (context, not this task's scope)
`cmd_archive` (§6.1, MEM-001, already merged) moves every feed document whose items are ALL routed into `.claude/feedbacks/archive/<YYYY-MM>.yaml` (month from the document's own `ts`), atomically, idempotently, byte-preserving the moved content. `cmd_pending` (§6.2, unchanged, untouched by this task) renders unrouted items only, from the active feed, tab-separated: `ts\titem-index\tcategory\tseverity\tsummary`.

## Interface — `archived [--since YYYY-MM]`
1. Glob `.claude/feedbacks/archive/*.yaml`; if the directory doesn't exist or has no matching files, print nothing (mirrors `pending`'s empty-feed behavior — no error, exit 0).
2. Parse each archive file's YAML documents (multi-doc, `---`-separated, same format `_load_feed` already handles for the active feed — reuse or mirror that parsing, since archive files are byte-identical copies of feed documents).
3. If `--since YYYY-MM` is given, only include documents whose own `ts`'s year-month is `>= YYYY-MM` (string comparison on the `YYYY-MM` prefix is sufficient and avoids a date-parsing dependency — `"2026-07" >= "2026-03"` behaves correctly lexicographically for zero-padded ISO year-month).
4. Render every item in every included document (archived items are, by construction, ALL routed — there is no unrouted/routed distinction to filter on here, unlike `pending`), using the EXACT SAME tab-separated line format as `cmd_pending`'s renderer (`ts\ti\tcategory\tseverity\tsummary`) — this is what "same rendering as pending" means per §6.3's own wording. Do not add a routing-column or archive-filename column; the DoD's acceptance bar is format parity, not extra metadata.
5. Order: by document `ts` ascending, then item index within a document (matches the natural chronological order files land in) — deterministic, no reliance on filesystem glob ordering across different months' files (sort the file list by filename, which sorts by `YYYY-MM` lexicographically since that's the whole filename).

## Decisions
No new helper module — this reuses the existing archive-directory path construction pattern already present in `cmd_archive` (`os.path.join(os.path.dirname(feed_path), "archive")`) and the existing multi-document YAML parsing approach `_load_feed` already uses for the active feed, applied per-archive-file instead of to the single feed file.
`--since` compares on the raw `YYYY-MM` string prefix of each document's normalized `ts`, not a parsed `datetime` — keeps this stdlib-only with zero new imports, consistent with the `_normalize_ts`/`_MONTH_RE` machinery `cmd_archive` already has for deriving a document's month.

## Out of scope for this task
§6.4 (retrospective integration running `archive` as its final step) — MEM-003, separate task.
§6.5 (commit-policy reconciliation, un-gitignoring `.claude/feedbacks/`) — MEM-004, separate task. This repo (Zugruul/development-skills) currently DOES gitignore `.claude/feedbacks/` (`.gitignore:17`), contradicting §6.5's "SHALL NOT gitignore" — that migration (removing the ignore line, committing the existing feed/archives) is MEM-004's job, not this task's. `archived`'s tests use a fixture repo, independent of this repo's own gitignore state.
§6.6 (emit/route unchanged) — no action needed, nothing in this task touches those commands.
