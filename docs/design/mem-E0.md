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

## Out of scope for MEM-002
§6.4 (retrospective integration running `archive` as its final step) — MEM-003, this doc's next section.
§6.5 (commit-policy reconciliation, un-gitignoring `.claude/feedbacks/`) — MEM-004, separate task. This repo (Zugruul/development-skills) currently DOES gitignore `.claude/feedbacks/` (`.gitignore:17`), contradicting §6.5's "SHALL NOT gitignore" — that migration (removing the ignore line, committing the existing feed/archives) is MEM-004's job, not this task's. `archived`'s tests use a fixture repo, independent of this repo's own gitignore state.
§6.6 (emit/route unchanged) — no action needed, nothing in this task touches those commands.

## MEM-003 — retrospective + build-next protocol: archive at close (§6.4)

**Components**: docs-only. `plugins/spec-workflow/skills/retrospective/SKILL.md`, `plugins/spec-workflow/skills/build-next/SKILL.md` (step 8, "Feedback"), `plugins/spec-workflow/skills/implement-task/SKILL.md` (step 4's inline Feedback paragraph — see scope note below), and `plugins/spec-workflow/README.md`'s retro-protocol summary. No script changes (`feedback.py archive` already exists, MEM-001).

**§6.4 exact text**: "WHEN the retrospective protocol completes routing THE SYSTEM SHALL run `archive` as its final feed step and commit feed + archives together (retrospective + build-next docs updated accordingly)."

**retrospective/SKILL.md** (steps 1-7, currently: Gather→Triage/route→Mint→Prune+graduate/retro-mark→Directory→Commit→Report): insert `feedback.py <root> archive` as the LAST feed action, after routing/triage (step 2) and after mint/prune/retro-mark (steps 3-4) — i.e. immediately before step 6's commit — and broaden step 6's commit wording from "the routed feed and any brain changes" to "the routed feed, archives, and any brain changes together," matching §6.4's "commit feed + archives together" literally.

**build-next/SKILL.md step 8 (Feedback)**: routing (`feedback.py route`) already happens here, AFTER step 7's retro (which independently commits brain changes via brains.md's own step 6 — that ordering is unchanged, retro's brain commit stays separate). Add `feedback.py archive` as the final action of step 8, after all `route` calls, followed by a commit of the routed feed + archives (this is a SEPARATE commit from step 7's brain commit, since step 7 already ran and committed before step 8 begins — do not try to merge them into one commit, that would require reordering steps 7/8, which is out of scope and not required by §6.4's wording).

**implement-task/SKILL.md step 4's Feedback paragraph**: duplicates build-next step 8's routing text inline (does not delegate to it) — apply the identical archive+commit addition here for consistency, since this is a standalone entry point per its own text ("Do not assume a wrapping build-next loop will run it for you").

**brains.md**: NOT touched for the feed/archive change — its own step 6 commit is BRAIN changes only (notes/links/directory), a separate concern from the feed. (implement-task's retro step already delegates fully to brains.md for brain-note mechanics; that delegation is unaffected by this task.)

**README.md**: the existing retro-protocol summary (describes mint/prune/graduate/directory/commit) gets a short addition mentioning `archive` runs as the final feed step before/with that commit — extends existing prose, no new heading.

**Test precedent**: `plugins/spec-workflow/tests/section-skill-contracts.sh` already has a grep-style content-assertion block for build-next/SKILL.md (`check "<label>" "<exact phrase>" "$BNBODY"` against the full file body). Mirror this pattern: read each edited SKILL.md's body into a shell variable, assert the exact new phrase (e.g. `feedback.py <root> archive` or similar) is present, and assert ordering where feasible (e.g. the archive instruction's text appears after the route instruction's text in the file, via `grep -n` line-number comparison or a substring-position check). No `evals/` directory changes — that's for LLM-graded behavioral cases, not applicable here.

**Out of scope for MEM-003**: any script change to `feedback.py` (archive already exists); §6.5's gitignore migration (MEM-004); brains.md's own brain-commit step (unaffected, separate concern from feed/archive).
