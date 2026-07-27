"""Turn pipeline: context builder + budgets + recall injection
(SPEC-ASSISTANT.md Sec8.2, Sec8.3, Sec9.1, AST-013, issue #311).

Two entry points:

    compose_context(persona_cfg, roster_provider, recall_fn, session_state,
                     user_message, budgets=None, *, cache=None)
        -> {"context_for_adapter": {...}, "chips": [...], "budget_report": {...}}

    run_turn(persona_cfg, roster_provider, recall_fn, session_state,
              user_message, *, budgets=None, cache=None, summarizer=None,
              get_adapter=adapters.get_adapter, adapter_kwargs=None,
              refresh_every=SUMMARY_REFRESH_EVERY_K_TURNS)
        -> {"text": str, "chips": [...], "usage": dict | None,
            "timings": dict | None, "updated_session_state": {...},
            "budget_report": {...}}   # budget_report is additive, not part
                                       # of the minimal Sec8.1 adapter shape

Nothing here imports engine.py, touches a subsystem queue (Sec9.5/Sec17.7:
turns never block on the distiller, index, or task queues), or spawns a
subprocess directly -- `run_turn` reaches a provider CLI only through the
injected `get_adapter` (default `adapters.get_adapter`), same isolation
discipline as engine.py (Sec17.1).

SEAMS this task respects (do not build the neighbors here):
  - roster_provider is a zero-arg callable returning a list of
    {"name", "one-liner", "available"} dicts, or an empty list. The real
    compiler is AST-061/E6; `default_roster_provider` below is a documented
    placeholder that always returns [].
  - session_state is an opaque-to-the-caller dict {"summary": str,
    "turns": [{"role", "text"}, ...], "turn_count": int}. This module
    decides WHEN to refresh the summary and HOW (via `summarizer`);
    persisting it to disk across process restarts is AST-014.
  - recall_fn(user_message) -> the exact dict brain.recall() returns
    ({"blocks", "seeds", "injected", "links_fired"}). `make_default_recall`
    wraps brain.recall as a thin default; the embeddings hop itself is
    AST-018 and already lives inside brain.recall (Sec9.1) -- this module
    only adds the query-embed CACHE seam around whatever recall_fn returns.

Token/char budgeting (Sec8.2 "hard total budget <= ~6k tokens... per-
component caps"): stdlib-only estimator, `len(text) // TOKENS_CHARS_PER_TOKEN`
(ceiling), matching brain.py's own CHARS_PER_TOKEN=4 heuristic so the two
budget systems agree on what a "token" costs without importing brain.py's
private constant.

Clip precedence (documented contract -- AST-014/E2 read `budget_report` to
know what happened, so these rules are load-bearing, not incidental):
  - user_message: NEVER truncated, always the raw string, full stop.
  - notes: rank-ordered PREFIX of the blocks recall_fn returned (recall
    already ranks by activation) -- take blocks in order until the next one
    would exceed the notes cap, then stop. Mirrors brain.recall's own
    budget-fitting loop (brain.py's `_render_block` loop: fit-or-break).
  - roster: same rank/list-order PREFIX rule as notes, applied to whichever
    order roster_provider() returned (not respecified elsewhere).
  - turns: OLDEST-FIRST drop -- keep the most recent entries (of the
    already-N<=6-windowed turns) that fit, dropping older ones first;
    chronological order is preserved in the rendered output.
  - summary: hard char-cap (a single blob of text, not itemized) -- plain
    slice to the cap.
  - persona: hard char-cap, same reasoning as summary (systemPrompt is one
    operator-authored blob, not itemized).
Total budget: the sum of the five per-component caps is deliberately kept
under TOKEN_BUDGET_TOTAL so there is headroom for the user message; if the
user message alone still pushes the total over budget, `budget_report`
reports `over_budget: True` truthfully rather than lying about a hidden
truncation -- Sec8.2's "user message" is never on the chopping block.
"""
import hashlib
import threading
import time
from collections import OrderedDict

from assistant import adapters

# ----------------------------------------------------------------- budgets

# chars-per-token heuristic, stdlib-only (Sec8.2). Matches brain.py's own
# CHARS_PER_TOKEN=4 so the two budget systems agree, without importing
# brain.py's private constant (this module has no hard dependency on brain
# module internals staying at 4 forever -- if brain.py's constant ever
# changes, notes budgeting still degrades gracefully, just less precisely).
TOKENS_CHARS_PER_TOKEN = 4

# Sec8.2 "hard total budget (<= ~6k tokens)".
TOKEN_BUDGET_TOTAL = 6000

# Per-component caps in TOKENS (documented choices -- Sec8.2 leaves the
# exact split to this task). Sum = 5300, leaving ~700 tokens of headroom
# under TOKEN_BUDGET_TOTAL for a normal-sized user message before
# `over_budget` can ever fire.
DEFAULT_COMPONENT_BUDGETS = {
    "persona": 800,
    "roster": 400,
    "notes": 1500,
    "summary": 600,
    "turns": 2000,
}

# Sec8.2 "last N turns (N<=6)". "Turn" here means one {role, text} entry in
# session_state["turns"] (a user message and its assistant reply are two
# entries) -- chosen because that is the literal unit session_state stores.
MAX_TURNS_WINDOW = 6

# Sec8.2 "refreshed every K turns" -- same entry-count unit as above: every
# 8 completed EXCHANGES (run_turn calls), not 8 raw entries.
SUMMARY_REFRESH_EVERY_K_TURNS = 8

# Sec9.1 query-embed cache: keyed on a hash of the raw message, bounded by
# count and TTL so a long session never grows this without limit.
RECALL_CACHE_MAX_ENTRIES = 256
RECALL_CACHE_TTL_SECONDS = 300

# brain.recall's own `k` (top-k recalled notes, Sec8.2).
RECALL_TOP_K = 8


def _resolve_budgets(budgets):
    resolved = {"total": TOKEN_BUDGET_TOTAL}
    resolved.update(DEFAULT_COMPONENT_BUDGETS)
    if budgets:
        resolved.update(budgets)
    return resolved


def estimate_tokens(text):
    """Stdlib-only chars/4 ceiling estimator (Sec8.2). Empty/None -> 0.

    ERROR BAND (review r2): chars/4 is a reasonable approximation for
    ASCII/Latin prose only. Dense scripts (CJK, emoji) tokenize at roughly
    1-2 tokens PER CHARACTER in real subword tokenizers, so this estimator
    can UNDERCOUNT such text 4-8x -- a CJK-heavy component can report
    over_budget=False while the real provider context is well past the
    budget. Codepoints above U+2E7F are therefore charged at 1 token each
    (still approximate, but conservative in the right direction); the
    residual error band for mixed text is documented, not hidden.
    """
    if not text:
        return 0
    dense = sum(1 for ch in text if ord(ch) > 0x2E7F)
    sparse = len(text) - dense
    return dense + (sparse + TOKENS_CHARS_PER_TOKEN - 1) // TOKENS_CHARS_PER_TOKEN


def _cap_chars(budgets, component):
    return budgets[component] * TOKENS_CHARS_PER_TOKEN


# ------------------------------------------------------------- query-embed cache


class QueryEmbedCache:
    """Sec9.1 seam: caches whatever `recall_fn` returns, keyed by a hash of
    the RAW user message -- Sec8.3 requires the raw message reach recall, so
    the cache key must be that exact string (a cache hit and a cache miss
    recall on IDENTICAL input, by construction). AST-018 slots the real
    embedding hop under this same cache later by wrapping a recall_fn that
    computes embeddings internally -- this cache never computes anything
    itself, it only memoizes recall_fn's return value.

    Bounded by `max_entries` (LRU eviction) and `ttl_seconds` (Sec9.1's p95
    budget "includes the embedding hop" -- a cache is only correct if stale
    entries expire; a fixed TTL is the stdlib-only way to bound staleness
    without a real invalidation signal, which recall_fn has no way to emit).
    `now` is injectable (default `time.monotonic`) so tests can control TTL
    expiry deterministically without sleeping.

    THREAD-SAFETY (review r2): all compound sequences (check-then-set,
    move_to_end, popitem) run under an internal threading.Lock -- engine HTTP
    request threads execute turns concurrently (Sec5a), so a shared
    per-assistant cache instance must not race.
    """

    def __init__(self, max_entries=RECALL_CACHE_MAX_ENTRIES,
                 ttl_seconds=RECALL_CACHE_TTL_SECONDS, now=time.monotonic):
        self._max_entries = max_entries
        self._ttl = ttl_seconds
        self._now = now
        self._store = OrderedDict()  # key -> (expires_at, value)
        self._lock = threading.Lock()  # review r2: compound ops must not race

    def get_or_compute(self, message, compute_fn):
        """Returns (value, hit: bool). Calls `compute_fn(message)` only on
        a miss (expired or absent key)."""
        key = hashlib.sha256((message or "").encode("utf-8")).hexdigest()
        now = self._now()
        with self._lock:
            cached = self._store.get(key)
            if cached is not None and cached[0] > now:
                self._store.move_to_end(key)
                return cached[1], True
        # compute OUTSIDE the lock -- recall can be slow and must not
        # serialize concurrent turns; a rare duplicate compute on a race is
        # cheaper than holding the lock across the embedding hop.
        value = compute_fn(message)
        with self._lock:
            self._store[key] = (now + self._ttl, value)
            self._store.move_to_end(key)
            while len(self._store) > self._max_entries:
                self._store.popitem(last=False)
        return value, False


# ------------------------------------------------------------- roster seam


def default_roster_provider():
    """Placeholder (E6/AST-061 compiles the real roster, Sec11.3). Returns
    an empty list -- an empty roster renders as a documented placeholder
    note in the composed context (`_render_roster` below), never a crash or
    a silently-omitted section."""
    return []


# ------------------------------------------------------------- recall seam


def make_default_recall(identities, root, role="assistant",
                         k=RECALL_TOP_K, budget=None):
    """Thin wrapper around brain.recall for the assistant's own brain
    (Sec4: `.claude/identities/assistant/brain/`). Imports brain.py lazily
    (inside the closure, not at module top) so importing turns.py alone
    never imports brain.py -- same lazy-import discipline adapters.py uses
    for provider modules (Sec17.1: isolation extends to import time)."""
    import brain as brain_module

    notes_budget = budget if budget is not None else DEFAULT_COMPONENT_BUDGETS["notes"]

    def _recall(user_message):
        # brain.recall's `keywords` param is a COMMA-separated list matched
        # against each note's `tags` (brain.py's `_split` only splits on
        # commas, never whitespace) -- so the raw free-text message this
        # closure receives (per Sec8.3, untransformed at the
        # compose_context boundary -- recall_fn itself IS this closure) is
        # tokenized into that comma-joined form ONLY for this brain.recall
        # call, never mutating what the caller passed in.
        keywords = ",".join((user_message or "").split())
        return brain_module.recall(identities, role, root,
                                    keywords=keywords,
                                    budget=notes_budget, k=k)

    return _recall


# ------------------------------------------------------------- chips


def _chip_from_block(block):
    """Parses one rendered note block (brain.py's `_render_block` output,
    all three tiers) into {"slug": str, "strength": int | None}.

    Block headers (brain.py Sec _format_header_line / _render_block):
      full:     "### [direct · 2× useful] slug-name  [strength 3]  ⚠ contested"
      one-liner: "### slug-name  ⚠ contested"
      title:     "- slug-name"
    Strength only appears in the full tier ("one-liner tier keeps
    flags-only" per brain.py's own docstring) -- title tier has neither
    bracket nor strength. `strength` is therefore optional by design
    (Sec8.3's chip shape is `{slug, strength?, activation?}`); `activation`
    is not derivable from recall's return shape (only per-slug `blocks`,
    aggregate `seeds`/`injected` counts, and link keys are returned -- see
    brain.py recall()'s docstring) so it is omitted, not faked.
    """
    first_line = block.split("\n", 1)[0]
    line = first_line
    if line.startswith("### "):
        line = line[4:]
    elif line.startswith("- "):
        line = line[2:]
    # strip one leading "[...]" confidence/tally bracket (full tier only;
    # no-op on one-liner/title, which never have one)
    if line.startswith("["):
        close = line.find("] ")
        if close != -1:
            line = line[close + 2:]
    slug = line.split(None, 1)[0] if line else ""
    strength = None
    marker = "[strength "
    idx = first_line.find(marker)
    if idx != -1:
        rest = first_line[idx + len(marker):]
        digits = rest.split("]", 1)[0]
        if digits.isdigit():
            strength = int(digits)
    return {"slug": slug, "strength": strength}


def _chips_from_recall(recall_result):
    return [_chip_from_block(b) for b in (recall_result or {}).get("blocks", [])]


# ------------------------------------------------------------- rendering + clipping


def _render_persona(persona_cfg):
    persona_cfg = persona_cfg or {}
    system_prompt = persona_cfg.get("systemPrompt") or ""
    names = persona_cfg.get("names") or []
    lines = [system_prompt] if system_prompt else []
    if names:
        main = names[0]
        aliases = names[1:]
        name_line = "You go by %s." % main
        if aliases:
            name_line += " Also known as: %s." % ", ".join(aliases)
        lines.append(name_line)
    return "\n".join(lines)


def _render_roster_entries(entries):
    """Renders `roster_provider()`'s entry dicts into system-prompt lines.

    AST-062 (SPEC-ASSISTANT.md Sec11.4, issue #337): "never present an
    unavailable ability as usable" -- an entry with `available` falsy
    renders its `reason` (`unavailable_reason` from the compiled
    CapabilityIndexEntry, threaded through by engine.py's
    `_roster_provider_for`) inline, so the persona's own system context
    states WHY a plausible-looking capability can't be used right now,
    never just a bare "(unavailable)" tag a model could talk past."""
    if not entries:
        return ["(no roster entries -- capability roster compilation lands in AST-061/E6)"]
    lines = ["Available capabilities:"]
    for entry in entries:
        name = entry.get("name", "?")
        one_liner = entry.get("one-liner") or entry.get("one_liner") or ""
        if entry.get("available"):
            lines.append("- %s (available): %s" % (name, one_liner))
        else:
            reason = entry.get("reason") or entry.get("unavailable_reason")
            suffix = " -- %s" % reason if reason else ""
            lines.append("- %s (unavailable%s): %s" % (name, suffix, one_liner))
    return lines


def _clip_prefix_items(items, cap_chars, sep="\n"):
    """Rank/list-order PREFIX clip: keep items in the given order until the
    next one would exceed cap_chars, then stop. Returns (rendered_str,
    clipped: bool) -- clipped is True iff at least one item was dropped."""
    out = []
    used = 0
    for item in items:
        add = len(item) + (len(sep) if out else 0)
        if used + add > cap_chars:
            return sep.join(out), True
        out.append(item)
        used += add
    return sep.join(out), False


def _clip_turns_oldest_first(turns, cap_chars):
    """Keeps the most recent entries that fit, dropping older ones first.
    Chronological order is preserved in the returned rendering."""
    rendered_lines = ["%s: %s" % (t.get("role", "user"), t.get("text", "")) for t in turns]
    kept_rev = []
    used = 0
    clipped = False
    for line in reversed(rendered_lines):
        add = len(line) + (1 if kept_rev else 0)  # "\n" separator
        if used + add > cap_chars:
            clipped = True
            break
        kept_rev.append(line)
        used += add
    kept = list(reversed(kept_rev))
    if len(kept) < len(rendered_lines):
        clipped = True
    return "\n".join(kept), clipped


def _truncate_chars(text, cap_chars):
    text = text or ""
    if len(text) <= cap_chars:
        return text, False
    return text[:cap_chars], True


def default_summarizer(old_summary, turns, cap_chars):
    """Cheap extractive placeholder (Sec9.2-adjacent -- a real provider-LLM
    summarizer is a later wiring decision, out of scope here): concatenates
    the existing summary with "role: text" lines for each turn in the
    refresh window, then hard-truncates to cap_chars."""
    parts = [old_summary] if old_summary else []
    for t in turns:
        parts.append("%s: %s" % (t.get("role", "?"), t.get("text", "")))
    combined = "\n".join(p for p in parts if p)
    return combined[:cap_chars]


# ------------------------------------------------------------- compose_context


def compose_context(persona_cfg, roster_provider, recall_fn, session_state,
                     user_message, budgets=None, *, cache=None):
    """Builds one turn's context under Sec8.2's budget discipline.

    `roster_provider` and `recall_fn` are injectable callables (may be
    None -- treated as `default_roster_provider` / a no-op recall
    returning an empty result, respectively, so callers who don't care
    about roster/recall yet don't have to wire fakes for them).
    `cache` is a QueryEmbedCache; pass the SAME instance across turns of one
    session to get cross-turn caching -- a fresh cache is created per call
    when omitted (i.e. no caching across calls unless the caller threads
    one through).
    """
    resolved = _resolve_budgets(budgets)
    session_state = session_state or {}
    roster_provider = roster_provider or default_roster_provider
    cache = cache if cache is not None else QueryEmbedCache()

    components = {}
    clipped_components = []

    # persona (+ names) -- hard char-cap, one operator-authored blob
    persona_text, persona_clipped = _truncate_chars(
        _render_persona(persona_cfg), _cap_chars(resolved, "persona"))
    components["persona"] = {
        "tokens": estimate_tokens(persona_text),
        "cap": resolved["persona"], "clipped": persona_clipped,
    }
    if persona_clipped:
        clipped_components.append("persona")

    # roster -- rank/list-order prefix clip, whole-entry granularity
    roster_entries = roster_provider() or []
    if not isinstance(roster_entries, list):
        raise TypeError(
            "roster_provider must return a list of entry dicts, got "
            f"{type(roster_entries).__name__} (review r2: a string here used "
            "to surface as a cryptic attribute error deep in rendering)"
        )
    roster_lines = _render_roster_entries(roster_entries)
    roster_text, roster_clipped = _clip_prefix_items(roster_lines, _cap_chars(resolved, "roster"))
    components["roster"] = {
        "tokens": estimate_tokens(roster_text),
        "cap": resolved["roster"], "clipped": roster_clipped,
    }
    if roster_clipped:
        clipped_components.append("roster")

    # recall -- Sec8.3: the RAW user message reaches recall_fn, untransformed
    if recall_fn is None:
        recall_result = {"blocks": [], "seeds": 0, "injected": 0, "links_fired": []}
    else:
        recall_result, _cache_hit = cache.get_or_compute(user_message, recall_fn)
    chips = _chips_from_recall(recall_result)

    # notes -- rank-order prefix clip, whole-block granularity (mirrors
    # brain.recall's own fit-or-break loop)
    blocks = (recall_result or {}).get("blocks", [])
    notes_text, notes_clipped = _clip_prefix_items(blocks, _cap_chars(resolved, "notes"), sep="\n\n")
    components["notes"] = {
        "tokens": estimate_tokens(notes_text),
        "cap": resolved["notes"], "clipped": notes_clipped,
    }
    if notes_clipped:
        clipped_components.append("notes")

    # rolling summary -- hard char-cap, one blob
    summary_text, summary_clipped = _truncate_chars(
        session_state.get("summary") or "", _cap_chars(resolved, "summary"))
    components["summary"] = {
        "tokens": estimate_tokens(summary_text),
        "cap": resolved["summary"], "clipped": summary_clipped,
    }
    if summary_clipped:
        clipped_components.append("summary")

    # last N<=6 turns -- oldest-first drop within that window
    all_turns = session_state.get("turns") or []
    windowed = all_turns[-MAX_TURNS_WINDOW:]
    turns_text, turns_clipped = _clip_turns_oldest_first(windowed, _cap_chars(resolved, "turns"))
    components["turns"] = {
        "tokens": estimate_tokens(turns_text),
        "cap": resolved["turns"], "clipped": turns_clipped,
    }
    if turns_clipped:
        clipped_components.append("turns")

    # user message -- NEVER truncated
    components["user_message"] = {
        "tokens": estimate_tokens(user_message), "cap": None, "clipped": False,
    }

    # AST-032 note-wins ordering: recalled notes render AFTER the rolling
    # summary (not the literal persona+roster+notes+summary+turns listing
    # order in Sec8.2's prose) so a note that contradicts a stale summary
    # wins by PROMPT-ORDER RECENCY -- the summary is a coarse, possibly
    # stale digest (regenerated only every K turns, Sec8.2/AST-032) while a
    # recalled note is the sharper, independently-ranked signal for THIS
    # turn; placing it later lets it override the summary's claim without
    # any explicit contradiction-detection logic. See docs/spec-deltas/
    # AST-032.md for the Sec8.2 ordering clarification this encodes.
    system_parts = [p for p in (persona_text, roster_text, summary_text, notes_text, turns_text) if p]
    system = "\n\n".join(system_parts)

    total_tokens = sum(c["tokens"] for c in components.values())
    over_budget = total_tokens > resolved["total"]

    context_for_adapter = {"system": system, "input": user_message}
    model = ((persona_cfg or {}).get("llm") or {}).get("model")
    if model:
        context_for_adapter["model"] = model

    budget_report = {
        "total_tokens": total_tokens,
        "total_cap": resolved["total"],
        "over_budget": over_budget,
        "components": components,
        "clipped_components": clipped_components,
    }

    return {
        "context_for_adapter": context_for_adapter,
        "chips": chips,
        "budget_report": budget_report,
    }


# ------------------------------------------------------------- run_turn


def run_turn(persona_cfg, roster_provider, recall_fn, session_state, user_message,
             *, budgets=None, cache=None, summarizer=None,
             get_adapter=adapters.get_adapter, adapter_kwargs=None,
             refresh_every=SUMMARY_REFRESH_EVERY_K_TURNS):
    """Runs one turn: compose -> adapter.complete -> advance session_state.

    Returns {"text", "chips", "usage", "timings", "updated_session_state"}
    (Sec8.1's adapter shape plus chips + session_state) with an additive
    "budget_report" key for callers (E2's overlay, debugging) that want it.
    """
    resolved = _resolve_budgets(budgets)
    composed = compose_context(persona_cfg, roster_provider, recall_fn,
                                session_state, user_message, budgets, cache=cache)

    provider = ((persona_cfg or {}).get("llm") or {}).get("provider")
    complete_fn = get_adapter(provider)
    result = complete_fn(composed["context_for_adapter"], **(adapter_kwargs or {}))

    updated_state = _advance_session_state(
        session_state or {}, user_message, result.get("text", ""),
        summarizer or default_summarizer, refresh_every,
        _cap_chars(resolved, "summary"))

    return {
        "text": result.get("text", ""),
        "chips": composed["chips"],
        "usage": result.get("usage"),
        "timings": result.get("timings"),
        "updated_session_state": updated_state,
        "budget_report": composed["budget_report"],
    }


def _advance_session_state(session_state, user_message, assistant_text,
                            summarizer, refresh_every, summary_cap_chars):
    turns = list(session_state.get("turns") or [])
    turns.append({"role": "user", "text": user_message})
    turns.append({"role": "assistant", "text": assistant_text})
    turn_count = int(session_state.get("turn_count", 0)) + 1
    summary = session_state.get("summary") or ""
    if refresh_every and turn_count % refresh_every == 0:
        window = turns[-(refresh_every * 2):]
        # Hard-cap the summarizer's own output too (defense in depth -- a
        # custom `summarizer` callable is not trusted to honor cap_chars on
        # its own; "summary: hard-capped" is this pipeline's invariant, not
        # a request the summarizer may decline).
        summary = summarizer(summary, window, summary_cap_chars)[:summary_cap_chars]
    return {"summary": summary, "turns": turns, "turn_count": turn_count}
