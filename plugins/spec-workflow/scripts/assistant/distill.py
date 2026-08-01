"""Distiller subsystem (SPEC-ASSISTANT.md Sec5a, Sec9.2, Sec9.5, E3, AST-030,
issue #322, docs/design/ast-E3.md).

Per Sec9.2 the distiller batches every N exchanges (never per-exchange),
minting new notes and bumping touched ones -- v1 does NOT merge, retire, or
aggregate notes (NG3; that is a later, explicitly-gated epic). Per Sec9.5
turns never block on the distiller: `process_batch` below is pure, testable
logic with no threading of its own, and `run_worker` is the loop body
engine.py's `distiller` worker slot (AST-010's WORKER_NAMES registry) binds
instead of its v1 heartbeat no-op -- the request thread that enqueues an
exchange-ref never waits on either of them.

v1 synthesis is DETERMINISTIC-extractive, not LLM: no metered/provider CLI
call is ever made from this module (a background worker calling a provider
would need its own enablement/gating design -- parked for a later epic, per
the design doc's Decisions section). Keyword/entity heuristics only; modest
quality is an accepted, documented trade-off -- the pipeline shape is the
deliverable, not summarization quality.

Every brain write goes through brain.py's library API (mint), which already
holds the identities-wide flock (Sec5a bullet 4/Sec17.5) -- the distiller
worker is the engine's single writer thread for brain mutations, so no
additional locking lives here. brain.py is imported LAZILY (inside functions,
never at module top) so importing distill.py alone never imports brain.py --
the same isolation discipline turns.make_default_recall and this module's
own `refresh_after_mint` already use (Sec17.1: isolation extends to import
time).
"""
import hashlib
import queue as queue_module
import re
import sys

from assistant import observability

# Sec9.2 "batch every N exchanges" default -- hard-coded for v1; an
# additive `distiller:` config knob is a later task once config grows one
# (design doc's Data models section).
DEFAULT_BATCH_N = 8

# How long run_worker's queue.get() blocks between stop_event checks. Small
# enough that stop() (5s join timeout, engine.py) always observes the
# thread exit promptly; large enough that an idle worker does not spin.
DEFAULT_POLL_TIMEOUT_SECONDS = 0.5

_WORD_RE = re.compile(r"[A-Za-z][A-Za-z'-]{2,}")

# A small, deliberately short stopword list -- this is keyword EXTRACTION,
# not a full NLP pipeline; filtering the highest-frequency function words is
# enough to keep the extracted tags from being dominated by "the"/"that"/
# "with" noise.
_STOPWORDS = frozenset({
    "the", "and", "for", "that", "this", "with", "from", "have", "has",
    "was", "were", "are", "you", "your", "our", "not", "but", "can", "will",
    "would", "could", "should", "into", "about", "then", "than", "when",
    "what", "which", "who", "how", "why", "there", "here", "just", "like",
    "also", "its", "it's", "them", "they", "their", "these", "those", "any",
    "all", "one", "two", "did", "does", "let", "get", "got",
})

_MAX_KEYWORDS = 5
_MAX_SNIPPET_CHARS = 160
_MAX_SNIPPET_LINES = 3


def _extract_keywords(text, limit=_MAX_KEYWORDS):
    """Frequency-ranked keyword extraction over `text` (deterministic:
    ties break alphabetically, so the same batch text always yields the
    same ranked keywords). Words under 3 chars or in `_STOPWORDS` are
    dropped. Returns [] for text with no qualifying words -- an empty
    batch, or one that is entirely stopwords/short tokens, mints nothing
    (see `process_batch`'s "no keywords -> no mint" rule)."""
    counts = {}
    for word in _WORD_RE.findall((text or "").lower()):
        if word in _STOPWORDS:
            continue
        counts[word] = counts.get(word, 0) + 1
    ranked = sorted(counts, key=lambda w: (-counts[w], w))
    return ranked[:limit]


def _batch_slug(exchanges):
    """A deterministic slug derived from the batch's own content -- the
    SAME batch (identical exchange text, in order) always yields the SAME
    slug, so a re-run of an already-processed batch bumps (re-mints) the
    same note rather than minting a duplicate. Uses a stdlib hash, not
    identity/timestamp, precisely so it is reproducible."""
    import hashlib

    h = hashlib.sha1()
    for exch in exchanges:
        h.update((exch.get("user") or "").encode("utf-8"))
        h.update(b"\x00")
        h.update((exch.get("assistant") or "").encode("utf-8"))
        h.update(b"\x00")
    return "distilled-" + h.hexdigest()[:12]


def _batch_body(exchanges, keywords):
    lines = ["Distilled from %d exchange(s)." % len(exchanges)]
    if keywords:
        lines.append("Keywords: " + ", ".join(keywords) + ".")
    for exch in exchanges[:_MAX_SNIPPET_LINES]:
        user = (exch.get("user") or "").strip()
        if user:
            lines.append("- " + user[:_MAX_SNIPPET_CHARS])
    return "\n".join(lines) + "\n"


def _bump_recalled_notes(brain_module, identities_dir, root, role, exchanges):
    """Bumps (re-mints, strength+1) every note a chip in `exchanges`
    recalled -- Sec9.2's "bumping touched ones". A chip is `{"slug": ...}`
    (turns.py's `_chips_from_recall` shape) carried on the exchange the
    engine enqueued. Re-mint preserves the note's existing body/tags/paths/
    entities/source/learned-from/source-note verbatim -- ONLY `confidence`
    is deliberately omitted (None) so an existing note's confidence is
    never silently touched by a bump, matching brain.mint's own "omit ->
    preserve" contract. A chip slug with no corresponding note (already
    pruned, or a stale/malformed chip) is skipped, not an error -- a bump
    is best-effort touch bookkeeping, not a required side effect."""
    bumped = []
    seen = set()
    for exch in exchanges:
        for chip in exch.get("chips") or []:
            slug = chip.get("slug") if isinstance(chip, dict) else chip
            if not slug or slug in seen:
                continue
            seen.add(slug)
            notes = brain_module.load_notes(identities_dir, role)
            note = notes.get(slug)
            if note is None:
                continue
            fm, body = note["fm"], note["body"]
            brain_module.mint(
                identities_dir, role, slug, root, body,
                tags=",".join(fm.get("tags") or []),
                paths=",".join(fm.get("paths") or []),
                entities=",".join(fm.get("entities") or []),
                source=fm.get("source") or "",
                learned_from=fm.get("learned-from") or "",
                source_note=fm.get("source-note") or "",
            )
            bumped.append(slug)
    return bumped


def mint_artifact_note(identities_dir, root, artifact, role="assistant"):
    """Chat-artifact memory (2026-07-29, human-directed): every file the
    assistant produces during a chat turn is minted as its own note --
    tagged #chat-artifact, carrying WHEN it was created, WHICH turn, a
    prompt excerpt, and a brain-relative link to the file -- so the brain
    remembers what was generated and recall/search can surface it later
    ("what did we generate yesterday"). Slug derives from the FILENAME, so
    re-generating the same file bumps (re-mints) the same note instead of
    duplicating. Same discipline as process_batch: brain.py imported
    lazily, every write through brain.mint()'s identities-wide flock, and
    this only ever runs on the distiller worker thread."""
    import brain as brain_module

    fname = (artifact.get("file") or "").strip()
    if not fname:
        return None
    slug_base = re.sub(r"[^a-z0-9-]+", "-", fname.lower()).strip("-") or "file"
    slug = "chat-artifact-" + slug_base
    created = artifact.get("created") or ""
    turn_id = artifact.get("turn_id") or ""
    prompt = (artifact.get("prompt") or "").strip()
    lines = [
        "Chat-generated artifact: [%s](media/chat/%s)" % (fname, fname),
        "",
        "Created: %s" % created,
        "Turn: %s" % turn_id,
    ]
    if prompt:
        lines += ["", 'Prompt (excerpt): "%s"' % prompt[:200]]
    return brain_module.mint(
        identities_dir, role, slug, root, "\n".join(lines) + "\n",
        tags="chat-artifact",
        source="assistant-chat",
    )


def _normalize_gap_excerpt(text):
    """Lowercase + collapsed-whitespace normalization used ONLY to compute
    `_gap_note_slug`'s dedup hash below -- the note BODY still renders the
    RAW excerpt verbatim, unmodified. Two excerpts that normalize
    identically are treated as "the same request" for dedup purposes: a
    case or whitespace-only difference collapses into one note.
    Non-ASCII limitation (documented, not fixed here): Python's
    locale-naive `str.lower()` does not round-trip cleanly for every
    script, so two visually-identical non-ASCII excerpts can rarely
    normalize to different strings and therefore mint separate notes
    instead of deduping -- an accepted, minor over-minting edge case, not
    a data-loss one (nothing is ever silently merged incorrectly by this
    limitation, only occasionally NOT merged when it ideally would be)."""
    return " ".join((text or "").strip().lower().split())


def _gap_note_slug(nearest, excerpt):
    """AST-071 slug (review round 1, MEDIUM #2): the ORIGINAL scheme (a
    40-char prefix of the slugified excerpt) had two independent bugs:
      (a) FLOODING -- near-identical requests that diverged anywhere
          within their first 40 characters got DISTINCT slugs, minting a
          fresh note per near-duplicate turn.
      (b) SILENT DATA LOSS -- two DIFFERENT requests that merely shared
          the same 40-character PREFIX (identical up to char 40, only
          diverging after it -- which the old scheme truncated away
          before it could matter) collapsed onto ONE slug: the second
          mint's `brain.mint()` bump silently overwrote/extended the
          first request's note instead of creating its own.

    Re-keyed on:
      - the SORTED nearest-capability names (so requests naming the exact
        same acquisition target group under one readable slug segment,
        independent of exact wording), and
      - a short hash of the `_normalize_gap_excerpt`-normalized FULL
        excerpt (collapses whitespace/case-only differences into one
        note; ANY other difference -- including one past the old scheme's
        40-char cutoff -- now hashes to a different digest and gets its
        own note).

    COLLISION SEMANTICS (documented, not a bug): two requests naming the
    SAME nearest-capability set whose excerpts normalize identically
    dedupe into one note by design (that IS "the same request", modulo
    case/whitespace). A 10-hex-char (40-bit) hash has a real but
    astronomically small collision probability for the note volume this
    function will ever see; a hash collision would silently bump an
    unrelated note rather than mint a new one -- an accepted, standard
    trade-off for a bounded, human-readable slug, not fixed here."""
    digest = hashlib.sha256(_normalize_gap_excerpt(excerpt).encode("utf-8")).hexdigest()[:10]
    if nearest:
        names_part = re.sub(r"[^a-z0-9-]+", "-", "-".join(sorted(nearest)).lower()).strip("-")[:40]
        names_part = names_part or "abilities"
    else:
        names_part = "unspecified"
    return "capability-acquire-plan-%s-%s" % (names_part, digest)


def mint_gap_note(identities_dir, root, gap_note, role="assistant"):
    """AST-071 (SPEC-ASSISTANT.md Sec11.8, docs/design/ast-E6.md sequence
    5): mints the capability-gap ACQUIRE-OFFER PLAN NOTE -- a parking-lot
    zettel, clearly tagged/titled so it is never mistaken for an installed
    capability or an enablement action. Drafting this note is NOT
    installation: this function never reads or writes
    `assistant.capabilities.*`, never touches project.yaml, and never
    invokes anything -- a human approves any real acquisition out-of-band
    (Sec11.8). Same discipline as `mint_artifact_note`: brain.py imported
    lazily (never at module top), one `brain.mint()` call under the
    identities-wide flock (atomic write + brain-events.jsonl emission come
    for free from that one call, Sec17.5), and this only ever runs on the
    distiller worker thread -- never the HTTP request thread that detected
    the gap (turns.py itself is queue-free, Sec9.5/Sec17.7; see
    `turns.capability_gap_reply`'s docstring for the payload this consumes).

    `gap_note` is the payload `turns._draft_capability_acquire_offer`
    built, with `turn_id`/`created` added by the caller (engine.py's
    `_enqueue_gap_note`, mirroring `_enqueue_artifact_note`'s own payload-
    shaping): `{"request_excerpt", "nearest": [name, ...], "total_enabled":
    int, "turn_id", "created"}`. Slug is `_gap_note_slug(nearest, excerpt)`
    -- see that function's docstring for the exact dedup scheme (sorted
    nearest names + a hash of the normalized excerpt) and its documented
    collision semantics; near-identical requests bump the SAME parked
    note, while genuinely different requests -- even ones sharing a long
    text prefix -- always land as distinct notes. NOTE (round 2, HIGH
    NEW-1): `nearest` is, in every request this function is reachable for
    today, ALWAYS an empty list (see `turns.capability_gap_reply`'s
    "ARCHITECTURAL NOTE" docstring -- `nearest_entries` provably returns
    `[]` for every gap that function can detect) -- so `nearest` alone
    CANNOT distinguish "nothing is enabled at all" from "N abilities are
    enabled but none matched"; branching the note body on `nearest`
    (an earlier version of this function did exactly that) asserted
    "No capabilities are currently enabled at all" even when the SAME gap
    event's own refusal text said otherwise -- a live, self-contradicting
    lie. The note body below branches on `total_enabled` instead, the
    SAME signal `turns._render_capability_gap_refusal` uses for its own
    three shapes, so the plan note and the refusal it was drafted
    alongside always agree. Because `nearest` is always `[]` in practice,
    `_gap_note_slug`'s `names_part` is, in every note this function mints
    today, the literal fallback `"unspecified"` -- production slugs read
    `capability-acquire-plan-unspecified-<hash>` until a future task (see
    docs/spec-deltas/346.md) gives this function a real nearest-ability
    signal to key off."""
    import brain as brain_module

    excerpt = (gap_note.get("request_excerpt") or "").strip()
    nearest = gap_note.get("nearest") or []
    total_enabled = gap_note.get("total_enabled") or 0
    turn_id = gap_note.get("turn_id") or ""
    created = gap_note.get("created") or ""

    slug = _gap_note_slug(nearest, excerpt)

    lines = [
        "# Capability acquisition plan (parking lot -- NOT an installed ability)",
        "",
        "This note is a DRAFT plan only. Nothing was installed or enabled --",
        "assistant.capabilities.* and project.yaml were never touched while",
        "drafting this note. A human must approve any acquisition out-of-band",
        "(SPEC-ASSISTANT.md Sec11.8) before anything is ever installed.",
        "",
        'Unmatched request (excerpt): "%s"' % excerpt[:200],
        "Turn: %s" % turn_id,
        "Created: %s" % created,
    ]
    # Branches on total_enabled (round 2, HIGH NEW-1), NOT on `nearest` --
    # see the docstring above for why `nearest` cannot tell these two
    # cases apart (it is always empty for both).
    if nearest:
        lines += ["", "Nearest enabled abilities considered (none matched well enough):"]
        lines += ["- %s" % name for name in nearest]
    elif total_enabled > 0:
        lines += ["", "%d capabilit%s currently enabled, but none matched this request."
                  % (total_enabled, "y is" if total_enabled == 1 else "ies are")]
    else:
        lines += ["", "No capabilities are currently enabled at all."]

    return brain_module.mint(
        identities_dir, role, slug, root, "\n".join(lines) + "\n",
        tags="capability-acquisition-plan,parking-lot",
        source="assistant-capability-gap",
    )


def process_batch(identities_dir, root, exchanges, role="assistant"):
    """The distiller's core logic (design doc's `distill.process_batch`
    contract): pure and testable without any thread/queue -- callers pass
    an already-collected batch of exchange dicts
    (`{"user", "assistant", "chips"?}`) and get back which notes were
    minted/bumped. Every side effect goes through brain.py's mint() (the
    identities-wide flock), imported lazily so importing this module alone
    never imports brain.py.

    v1 mints AT MOST ONE new note per batch (the batch-level distilled
    summary -- Sec9.2 does not ask for per-exchange notes, and per-exchange
    minting would flood the brain with N notes every N exchanges). No
    merge, retire, or aggregate call is ever made here (NG3) -- v1 only
    mints and bumps.

    Returns {"minted": [slug, ...], "bumped": [slug, ...]}. An empty batch
    is a no-op (both lists empty), never an error.
    """
    if not exchanges:
        return {"minted": [], "bumped": []}

    import brain as brain_module

    bumped = _bump_recalled_notes(brain_module, identities_dir, root, role, exchanges)

    minted = []
    text = "\n".join(
        "%s\n%s" % (exch.get("user") or "", exch.get("assistant") or "")
        for exch in exchanges
    )
    keywords = _extract_keywords(text)
    if keywords:
        slug = _batch_slug(exchanges)
        body = _batch_body(exchanges, keywords)
        brain_module.mint(
            identities_dir, role, slug, root, body,
            tags=",".join(keywords),
            source="distiller batch (%d exchanges)" % len(exchanges),
        )
        minted.append(slug)

    return {"minted": minted, "bumped": bumped}


def refresh_after_mint(identities, root, role="assistant"):
    """SPEC-ASSISTANT.md Sec9.3 seam: "WHEN the distiller mints THE SYSTEM
    SHALL refresh the embeddings index so new notes are recallable within
    one batch cycle." AST-018 delivered this hook; AST-030's `run_worker`
    below calls it once per batch that actually minted something. Thin
    wrapper over brain.refresh_index, imported lazily (inside the function,
    not at module top) so importing distill.py alone never imports brain.py
    -- same lazy-import discipline turns.make_default_recall uses for the
    same reason (Sec17.1: isolation extends to import time).

    `root` is accepted (unused by refresh_index itself) to keep this
    seam's signature consistent with the rest of the assistant subsystem's
    identities/root/role calling convention.
    """
    import brain as brain_module

    return brain_module.refresh_index(identities, role)


def run_worker(q, stop_event, batch_n=DEFAULT_BATCH_N, role="assistant",
                poll_timeout=DEFAULT_POLL_TIMEOUT_SECONDS, traces_queue=None):
    """The `distiller` worker body engine.py's `start()` binds into the
    AST-010 `distiller` slot, replacing the v1 heartbeat no-op. Drains `q`
    for items shaped `{"root": str, "identities": str, "exchange": dict}`
    (engine.py's `_enqueue_distill`), buffers PER ROOT (Sec9.2/AST-033: two
    assistants' exchanges never mix into the same batch -- role privacy and
    digest correctness), and calls `process_batch` once a root's buffer
    reaches `batch_n`. Also drains `artifact_note` (chat-artifact memory)
    and `gap_note` (AST-071, Sec11.8 capability-acquire-offer plan notes)
    items -- both mint IMMEDIATELY, never batched, via
    `mint_artifact_note`/`mint_gap_note` respectively.

    Runs entirely on ITS OWN thread: nothing here ever runs on an HTTP
    request thread, and `q.get(timeout=poll_timeout)` bounds how long the
    loop can go without checking `stop_event`, so `engine.stop()`'s bounded
    join always succeeds promptly (Sec9.5: turns never block on this
    worker, and this worker never blocks the engine's shutdown).

    Failure posture (design doc "Decisions"): an exception raised while
    processing one item is caught, logged to stderr, and the loop
    continues -- it never crashes the thread and never retries in a tight
    loop. The durable source of truth is the transcript (session.jsonl,
    already fsync'd by SessionStore before the item was even enqueued), so
    a dropped/failed batch loses only that batch's distillation, never the
    exchange itself.

    `traces_queue` (AST-040, SPEC-ASSISTANT.md §10.1) is OPTIONAL and
    defaults to `None` so every existing caller/test that constructs this
    worker without one keeps working unchanged. When given (engine.py's
    `start()` passes `self.queues["traces"]`), a `distill.batch` event is
    emitted -- enqueue-only via `observability.emit`, on THIS thread, never
    the HTTP request thread -- once per batch actually processed, whether
    or not it minted anything.
    """
    buffers = {}  # root -> [exchange, ...]
    while not stop_event.is_set():
        try:
            item = q.get(timeout=poll_timeout)
        except queue_module.Empty:
            continue
        try:
            if not isinstance(item, dict):
                continue
            root = item.get("root")
            identities_dir = item.get("identities")
            # chat-artifact items (2026-07-29): minted immediately, never
            # batched -- one file, one note, same worker thread, same
            # park-and-continue failure posture as a batch.
            artifact = item.get("artifact_note")
            if artifact is not None and root and identities_dir:
                mint_artifact_note(identities_dir, root, artifact, role=role)
                continue
            # capability-gap items (AST-071, Sec11.8): also minted
            # immediately, never batched -- a parking-lot plan note is a
            # one-off draft per gap, not something to accumulate into a
            # distilled summary.
            gap = item.get("gap_note")
            if gap is not None and root and identities_dir:
                mint_gap_note(identities_dir, root, gap, role=role)
                continue
            exchange = item.get("exchange")
            if not root or not identities_dir or exchange is None:
                continue
            bucket = buffers.setdefault(root, [])
            bucket.append(exchange)
            if len(bucket) >= batch_n:
                batch, buffers[root] = bucket, []
                result = process_batch(identities_dir, root, batch, role=role)
                if result.get("minted"):
                    refresh_after_mint(identities_dir, root, role=role)
                if traces_queue is not None:
                    observability.emit(traces_queue, root, {
                        "kind": "distill.batch",
                        "payload": {
                            "batch_size": len(batch),
                            "minted": result.get("minted", []),
                            "bumped": result.get("bumped", []),
                        },
                    })
        except Exception as exc:  # park-and-continue -- never kill the worker thread
            sys.stderr.write("distiller worker: batch failed: %s\n" % exc)
        finally:
            q.task_done()
