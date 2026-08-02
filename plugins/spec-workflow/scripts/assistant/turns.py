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
import json
import re
import threading
import time
from collections import OrderedDict, namedtuple

from assistant import adapters
from assistant import capability_index

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


def persona_char_budget(budgets=None):
    """Public accessor (task #486): the actual runtime CHAR clip applied to
    the rendered persona component (`_render_persona` -- systemPrompt PLUS
    the names line) at compose time. `DEFAULT_COMPONENT_BUDGETS["persona"]`
    is in TOKENS, not chars -- this is `_cap_chars(_resolve_budgets(budgets),
    "persona")`, the exact conversion `compose_context` itself applies, so a
    caller outside this module (setup.py's `set_persona`, which warns a
    human composing a persona about the real runtime clip) never has to
    hand-duplicate the token->char math or silently drift from it if the
    default ever changes. `budgets`, like `compose_context`'s own param, is
    an optional override of the defaults."""
    return _cap_chars(_resolve_budgets(budgets), "persona")


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


# ------------------------------------------------------- capability gap (AST-071, Sec11.8)


# Sec11.8 "nearest enabled abilities" -- how many to name in a refusal.
# Deliberately smaller than roster_for_turn's own top-N (a refusal names a
# handful of closest candidates, not a full roster dump).
NEAREST_ABILITIES_TOP_N = capability_index.DEFAULT_NEAREST_TOP_N

CapabilityGap = namedtuple("CapabilityGap", ["text", "nearest", "plan_note"])


def _render_capability_gap_refusal(nearest, total_enabled, available_count):
    """Composes the deterministic, in-persona refusal text (Sec11.8: "SHALL
    say so in-persona"). THREE distinct shapes (review round 1, HIGH #1 --
    a two-shape version conflated "nothing installed" with "something is
    installed but none of it is relevant", which reads as the SAME honest
    admission when it is not: an operator who installed a capability wants
    to know their assistant HAS one, just not a matching one, versus an
    operator who installed nothing at all):

      1. `total_enabled == 0` -- nothing is enabled at all. The plain
         "nothing installed" admission.
      2. `total_enabled > 0` but `nearest` is empty -- `capability_index.
         nearest_entries` found no entry with ANY relevance signal for
         this query (every entry scored exactly 0.0, the same condition
         that made `roster_for_turn` return `[]` in the first place -- see
         `capability_gap_reply`'s docstring). States how many abilities
         ARE enabled without naming any of them (there is nothing
         truthful to name -- see the round-1 finding: this is, in
         practice, the ONLY populated-index shape `capability_gap_reply`
         can currently produce). `total_enabled` counts every ENABLED
         entry in the index, which -- per the "two invisibility tiers"
         design (capability_index.py's own module docstring) -- includes
         enabled-but-UNPROVISIONED entries; review round 2 (NEW-5) flagged
         that "I have N abilities enabled" alone overstates what is
         actually USABLE when some of those N are not provisioned, so this
         shape states BOTH counts: "N enabled (M available)" (M =
         `available_count`, i.e. entries with `provisioned_ok`).
      3. `nearest` is non-empty -- names each one, in ranked order. Per
         Sec11.4 ("never present an unavailable ability as usable"), an
         unprovisioned-but-enabled nearest entry is still named, but WITH
         its unavailable reason -- naming it is honest; omitting it would
         hide that it exists at all, and presenting it as usable would
         violate Sec11.4 directly. (Not reachable via `capability_gap_reply`
         today -- see that function's docstring -- but fully implemented
         and directly unit-tested, e.g.
         section-assistant-turns.sh's "_render_capability_gap_refusal"
         cases, so the branch cannot silently regress.) Per-entry
         availability is already precise here (each unavailable entry
         states its own reason), so this shape does not repeat the
         N-enabled/M-available summary shape 2 uses."""
    if total_enabled == 0:
        return ("I do not have any abilities enabled right now, so I cannot "
                 "help with that -- there is nothing installed to try.")
    if not nearest:
        return ("I have %d abilit%s enabled (%d available), but none of them "
                 "are related to that request."
                 % (total_enabled, "y" if total_enabled == 1 else "ies", available_count))
    lines = ["I do not have an ability that covers that request.",
             "The closest I have enabled:"]
    for entry in nearest:
        line = "- %s: %s" % (entry.name, entry.one_liner or "(no description)")
        if not entry.provisioned_ok:
            reason = entry.unavailable_reason or "not currently available"
            line += " (unavailable -- %s)" % reason
        lines.append(line)
    return "\n".join(lines)


def _draft_capability_acquire_offer(user_message, nearest, total_enabled, requested_name=None):
    """Sec11.8 "MAY offer to acquire the ability by drafting a plan into the
    brain repo (parking lot)". MAY-offer POLICY (review round 2, NEW-2 --
    an orchestrator decision that REVERSED round 1's "only when
    total_enabled > 0" gate): the offer is drafted EVERY time
    `capability_gap_reply` decides there is a genuine gap, unconditionally
    -- including when `total_enabled == 0` (a completely bare assistant
    with nothing installed at all). Rationale (recorded on task #508): the
    bare-assistant case is EXACTLY the one whose unmet requests are most
    worth parking -- it is the strongest signal of all that something
    should be acquired, and gating it out (round 1's choice) suppressed
    the most useful case rather than a marginal one. This is the simplest
    possible reading of "MAY" that stays fully deterministic (never a
    fresh LLM guess about whether to bother); drafting is cheap and a
    human still has to approve any real acquisition out-of-band regardless
    (Sec11.8), so an always-drafted note is never itself a commitment.

    `total_enabled` is carried in the returned payload (round 2, HIGH
    NEW-1) so `distill.mint_gap_note` can branch the minted note's body on
    it -- NOT on `nearest`, which is provably always `[]` for every gap
    this module can currently detect (see `capability_gap_reply`'s
    "ARCHITECTURAL NOTE") and therefore cannot, by itself, distinguish
    "nothing enabled at all" from "N enabled but none matched". Branching
    on `nearest` alone (an earlier version of this function's caller did
    exactly that) made the minted note assert "No capabilities are
    currently enabled at all" even when `total_enabled` was 2 -- a live
    contradiction against the refusal text from the SAME gap event, which
    round 2 (NEW-1) fixed by threading this field through.

    Returns a plain PAYLOAD dict, not a minted note -- this module never
    touches a queue or calls brain.mint() itself (Sec9.5/Sec17.7, see the
    NO_QUEUE_TOUCH invariant test in section-assistant-turns.sh, which
    re-scans this whole module's source). The caller (engine.py) is
    responsible for enqueuing this payload onto the distiller worker's
    queue (the engine's one sanctioned brain-write thread, Sec17.5) --
    `distill.mint_gap_note` is the function that actually mints it, adding
    `turn_id`/`created` to this payload before handing it off (mirrors
    `_enqueue_artifact_note`'s own payload-shaping).

    `requested_name` (#508, optional, `None` by default -- every
    pre-#508 caller is unaffected): when `capability_gap_reply` is called
    with a `requested_name` (an explicit, structured directive that failed
    to resolve), it is carried in this payload too, alongside `nearest`
    (which, for THAT call shape, is scored off the requested name itself
    -- see `capability_gap_reply`'s docstring -- and is therefore no
    longer provably always `[]`, per owner decision 3 in docs/spec-deltas/
    applied/346.md: 'production gap-note slugs become meaningful only once
    a real nearest signal exists')."""
    payload = {
        "request_excerpt": (user_message or "")[:200],
        "nearest": [entry.name for entry in nearest],
        "total_enabled": total_enabled,
    }
    if requested_name is not None:
        payload["requested_name"] = requested_name
    return payload


def capability_gap_reply(index, user_message, *, embed_fn=None,
                          nearest_top_n=NEAREST_ABILITIES_TOP_N,
                          roster_top_n=None, requested_name=None):
    """SPEC-ASSISTANT.md Sec11.8, AST-071, docs/design/ast-E6.md sequence 5:
    "roster/index produce no match for a request -> turns.py returns an
    in-persona refusal naming the nearest enabled abilities (from the
    index, not a fresh LLM guess) and MAY draft an acquire-offer plan note
    into the brain repo." (See `_draft_capability_acquire_offer`'s
    docstring for the current MAY-offer policy -- round 2 made this an
    UNCONDITIONAL draft on every gap, including a totally bare index.)

    Runs off an ALREADY-COMPILED `index` (Sec11.3: no index recompute in
    the request path) -- the exact same `capability_index.roster_for_turn`
    evaluation the turn's own roster injection already performs (see
    engine.py's `_roster_provider_for`), so this function detects a gap by
    re-running that SAME pure, in-memory, no-I/O scoring rather than
    inventing a second notion of "matches".

    Returns `None` when there is no gap: either `roster_for_turn` found a
    genuine candidate list (a real, usable match), or it returned the
    `AskInsteadOfGuess` sentinel (a DIFFERENT, already-handled AST-061
    concern -- a tie or low-confidence single winner still means something
    PLAUSIBLY matched, which is not what Sec11.8 is about). Only the
    `roster_for_turn() == []` case -- Sec11.3's own docstring flags this
    exact branch as "AST-071's capability-gap handling, not this task" --
    is a gap: covers BOTH a completely empty index (nothing installed at
    all) and a nonempty index where nothing had ANY relevance signal for
    this query.

    ARCHITECTURAL NOTE (review round 1, HIGH #1 -- read before assuming
    the named-ability refusal shape fires in practice): `roster_for_turn`
    returns `[]` if and only if its max-scoring entry's own score is
    `<= 0.0` -- and since `_score` never returns a negative number, that
    condition means EVERY entry scored EXACTLY 0.0. `nearest_entries`
    (called below with the SAME `index`/`query`, hence the SAME `_score`
    results) now EXCLUDES zero-score entries (review round 1 fix). So
    whenever this function detects a gap at all, `nearest` is PROVABLY
    always `[]` too -- the "name specific nearest abilities" refusal shape
    is fully implemented and independently unit-tested (see
    `_render_capability_gap_refusal` and `capability_index.
    nearest_entries`'s own test coverage) but is NOT reachable through
    THIS function's public entry point today. Only `total_enabled` (zero
    vs. nonzero) varies across real calls. A further consequence (review
    round 2, NEW-3): in production, when a real embeddings capability is
    available, `_score` uses cosine similarity, which is essentially NEVER
    exactly 0.0 for real embedding vectors, even for semantically
    unrelated text -- so in EMBEDDING MODE, `roster_for_turn() == []` (and
    therefore this function's gap detection) may rarely if ever fire at
    all; the whole capability-gap flow is, today, effectively
    keyword-fallback-only (it reliably engages when the embeddings
    capability itself is unavailable/degraded, forcing every entry's
    `embedding` to `None`). Both findings are recorded in
    docs/spec-deltas/346.md, alongside task #508's production-wiring
    scope, which owns deciding whether/how to loosen either condition.

    On a gap, returns a `CapabilityGap(text, nearest, plan_note)`:
      - `text`: the deterministic in-persona refusal -- see
        `_render_capability_gap_refusal`'s docstring for its three shapes
        (nothing enabled / something enabled but nothing related / named
        candidates, the last of which is the unreachable-today shape the
        architectural note above explains).
      - `nearest`: up to `nearest_top_n` `CapabilityIndexEntry` objects
        from `capability_index.nearest_entries` -- always `[]` for any gap
        this function can currently detect (see the architectural note).
      - `plan_note`: a payload dict for the CALLER to hand to the async
        mint queue (see `_draft_capability_acquire_offer`'s docstring for
        the current unconditional-draft policy) -- always a dict, never
        `None`, on any gap; never minted here, never blocking, never
        touching `assistant.capabilities.*` or project.yaml (Sec11.8:
        installation/enablement SHALL require human approval; this
        function contains no installation logic whatsoever).

    WIRING NOTE (flagged design call, docs/spec-deltas/346.md; production
    wiring is task #508, not this one): callers should treat a non-`None`
    result as background-only signal (trace + plan-note draft) rather than
    unconditionally replacing every turn's LLM-generated reply with `text`
    -- an index with few or no capabilities installed (the common v1
    state) would otherwise turn EVERY ordinary chat message into a
    refusal, which Sec11.3's own roster-injection contract explicitly
    guards against ("ordinary chat turns... completely unaffected").
    Detecting whether a given user_message was actually AN ACTION REQUEST
    (as opposed to ordinary conversation) is a natural-language judgment
    call this function deliberately does not make -- "never a fresh LLM
    guess" (Sec11.8) rules out asking the model, and no deterministic,
    stdlib-only substitute reliably distinguishes the two. This function's
    OWN contract is unconditional and honest: called with an index and a
    message, it reports the true state of that index/query match (or its
    absence) every time -- what a caller does with a `None` vs. a
    populated result is that caller's decision.

    `requested_name` (#508, optional, `None` by default -- every
    pre-#508 caller/behavior is completely unaffected): the ANSWER to the
    exact gap this docstring's ARCHITECTURAL NOTE and docs/spec-deltas/
    applied/346.md's owner comment (1) flagged as missing -- "the gap
    needs a signal that fires in embedding mode: gap when the model
    EXPLICITLY requested an action AND resolution fails, not just
    score==0." When a caller (engine.py, having just parsed an explicit
    `Sec.508` directive off the model's own reply) supplies
    `requested_name`, this function switches its ENTIRE gap-detection
    rule: instead of re-running `roster_for_turn` and checking for `[]`
    (a relevance-SCORE-based signal that `_score`'s cosine path makes
    "essentially never exactly 0.0" for real embeddings, per the
    architectural note above), it resolves `requested_name` against
    `index` BY NAME (`capability_index.resolve_by_name`, case-
    insensitive, exact-match, zero relevance scoring involved) -- a
    binary, deterministic, embedding-mode-INDEPENDENT signal: either the
    exact capability the model asked for exists and is enabled, or it
    does not. `roster_for_turn`/`AskInsteadOfGuess` are NEVER consulted
    on this path (they answer a different question -- "what's plausibly
    relevant to this free-text message" -- than "does the capability I
    was explicitly told to invoke actually resolve").

    A resolving name is never a gap (returns `None` immediately -- the
    caller already has what it needs to proceed to invocation). An
    unresolved name IS a gap, and `nearest` is then scored off a query
    built from `requested_name` itself (not the raw `user_message`) --
    a sharper, more specific signal than the ambient conversational text,
    which is WHY `nearest` is no longer provably always `[]` on this path
    (owner decision 3: "production gap-note slugs become meaningful only
    once a real nearest signal exists"). `_draft_capability_acquire_offer`
    also receives `requested_name` so the minted plan note/slug can key
    off the actual requested capability, not just an excerpt hash."""
    if requested_name is not None:
        if capability_index.resolve_by_name(index, requested_name) is not None:
            return None  # the exact requested name DOES resolve -- not a gap
        query = capability_index.embed_query(requested_name, embed_fn)
    else:
        roster_top_n = (roster_top_n if roster_top_n is not None
                         else capability_index.DEFAULT_ROSTER_TOP_N)
        query = capability_index.embed_query(user_message, embed_fn)
        roster_result = capability_index.roster_for_turn(index, query, roster_top_n)
        if not (isinstance(roster_result, list) and not roster_result):
            return None  # a real match, or AskInsteadOfGuess -- not a gap

    entries = index.entries if index else ()
    nearest = capability_index.nearest_entries(index, query, nearest_top_n)
    total_enabled = len(entries)
    available_count = sum(1 for e in entries if e.provisioned_ok)
    return CapabilityGap(
        text=_render_capability_gap_refusal(nearest, total_enabled, available_count),
        nearest=nearest,
        plan_note=_draft_capability_acquire_offer(user_message, nearest, total_enabled, requested_name),
    )


# ------------------------------------------------------- capability directive (#508, Sec9.4/Sec11.5)


# The ONE greppable, model-facing syntax a reply uses to request a
# capability invocation (docs/spec-deltas/508.md): a single fenced code
# block whose LANGUAGE TAG is exactly this constant, containing one JSON
# object `{"name": "<capability-name>", "params": {...}}`. Chosen over any
# vaguer "just mention the capability by name" convention because a
# fenced, tagged, JSON-shaped block is trivially greppable/parseable and
# unambiguous to strip from the user-visible reply -- "never by vibes" is
# the whole point (a similarity score is not a request).
CAPABILITY_DIRECTIVE_FENCE_LANG = "capability"

# Built from chr(96) rather than a literal backtick string: this constant
# itself never needs to appear inside a bash heredoc, but every TEST that
# exercises it does, and a raw literal backtick (or an unpaired quote)
# inside a heredoc nested in a bash $(...) command substitution trips a
# well-known bash lexer quirk (cumulative quote-parity tracking that
# ignores heredoc quoting) -- documented here once so the convention is
# discoverable from the constant itself, not just from the test files.
_CAPABILITY_FENCE_TOKEN = chr(96) * 3

# #508 round-1 review, finding 2/3: the opening fence is anchored to the
# START OF A LINE (re.MULTILINE `^`) -- a fence mentioned mid-sentence
# ("like this: ```capability...") is prose ABOUT the syntax, not a real
# fenced block, and must never match. re.IGNORECASE covers a case-varied
# language tag (```Capability, ```CAPABILITY -- the only letters in this
# pattern are the tag itself, so IGNORECASE has no other effect). The
# closing fence must end its own line too (trailing spaces/tabs allowed).
_CAPABILITY_DIRECTIVE_RE = re.compile(
    r"^" + re.escape(_CAPABILITY_FENCE_TOKEN) + CAPABILITY_DIRECTIVE_FENCE_LANG
    + r"[ \t]*\n(.*?)\n?" + re.escape(_CAPABILITY_FENCE_TOKEN) + r"[ \t]*$",
    re.DOTALL | re.MULTILINE | re.IGNORECASE,
)

# #508 round-1 review, finding 2: a DANGLING opening fence with no
# matching close (e.g. a reply truncated mid-JSON by a token limit).
# `parse_capability_directives` only ever runs this against text that has
# ALREADY had every COMPLETE pair (`_CAPABILITY_DIRECTIVE_RE` above)
# stripped out -- so any leftover occurrence of the opening marker is, by
# construction, unterminated; matches to end-of-string.
#
# #508 round-2 review, NEW-LOW: the original `\b.*\Z` suffix used a bare
# word-boundary after the language tag, which false-positives on ANY
# unrelated fenced block whose tag merely STARTS WITH "capability" (e.g.
# ```capability-notes, ```capability.md -- `\b` only requires a
# word/non-word transition, and both `-` and `.` are non-word characters,
# so the boundary is satisfied immediately after "capability" regardless
# of what follows). That match then deleted EVERY character from that
# point to end-of-string -- real, unrelated content, plus the closing
# fence of an entirely different code block -- and reported a spurious
# `CapabilityDirectiveError`. `[ \t]*$` requires "capability" to be the
# COMPLETE tag on its own line (only trailing spaces/tabs allowed before
# the line ends) -- the SAME discipline `_CAPABILITY_DIRECTIVE_RE`'s
# opening fence already applies -- so a genuinely dangling directive
# (nothing else on that line) still matches, while `capability-notes`/
# `capability.md` (real, non-whitespace characters immediately after the
# tag, on the SAME line) never does.
_CAPABILITY_DANGLING_OPEN_RE = re.compile(
    r"^" + re.escape(_CAPABILITY_FENCE_TOKEN) + CAPABILITY_DIRECTIVE_FENCE_LANG + r"[ \t]*$.*\Z",
    re.DOTALL | re.MULTILINE | re.IGNORECASE,
)

CapabilityDirective = namedtuple("CapabilityDirective", ["name", "params"])
CapabilityDirectiveError = namedtuple("CapabilityDirectiveError", ["raw", "reason"])


def _parse_one_directive(raw):
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, ValueError) as exc:
        return CapabilityDirectiveError(raw=raw, reason=f"invalid JSON: {exc}")
    if not isinstance(data, dict):
        return CapabilityDirectiveError(raw=raw, reason=f"must be a JSON object, got {type(data).__name__}")
    name = data.get("name")
    if not isinstance(name, str) or not name.strip():
        return CapabilityDirectiveError(raw=raw, reason="must carry a non-empty string 'name'")
    params = data.get("params", {})
    if not isinstance(params, dict):
        return CapabilityDirectiveError(raw=raw, reason=f"'params' must be a JSON object, got {type(params).__name__}")
    return CapabilityDirective(name=name.strip(), params=params)


def parse_capability_directives(reply_text):
    """Parses EVERY ```capability fenced block out of `reply_text` (Sec9.4/
    Sec11.5, docs/spec-deltas/508.md's directive contract) and returns
    `(visible_text, directives, actionable)`:

      - `visible_text`: `reply_text` with every matched fenced block
        REMOVED (never leaked to the user) -- valid or not, complete or
        dangling: a directive block is never something a user should see
        raw JSON for, whatever shape it took. Runs of 3+ blank lines left
        behind by the removal are collapsed to a single blank line, and
        the whole result is stripped, so removing a mid-reply block does
        not leave a visible gap of empty lines.
      - `directives`: an ORDERED list, one entry per fenced block found (in
        the order they appeared -- a dangling/unterminated block, if any,
        always sorts last since it can only ever be found after every
        complete pair has already been extracted), each either a
        `CapabilityDirective(name, params)` (valid: the block parsed as
        JSON, was an object, and carried a non-empty string `name`;
        `params` defaults to `{}` when absent, and is itself rejected as
        an error if present but not a JSON object) or a
        `CapabilityDirectiveError(raw, reason)` (invalid: unparseable
        JSON, not a JSON object, `name` missing/empty/non-string, `params`
        present but not itself an object, OR an unterminated fence with no
        closing marker at all) -- this function makes NO decision about
        which directive (if any) a caller should act on beyond the
        `actionable` field below; v1's "one invocation per turn, extra
        directives ignored+traced" policy is the CALLER's decision
        (engine.py), applied uniformly regardless of whether the extra
        directive came from this same reply or a later same-turn
        follow-up completion.
      - `actionable`: the ONE `CapabilityDirective` (never a
        `CapabilityDirectiveError`) this reply's own SHAPE actually
        requests right now, or `None`. Two conditions must BOTH hold for
        `directives[0]` to become `actionable` (round-1 review finding
        3 -- "teach-then-quote": a model DEMONSTRATING the syntax inside
        an explanation, then continuing with more prose, must never be
        treated as a real invocation, live-confirmed by review):
          1. `directives[0]` parsed as a valid `CapabilityDirective`
             (never an Error -- a malformed FIRST directive is handled on
             its own dedicated path by the caller, UNCONDITIONALLY,
             regardless of position -- see the caller's own docstring).
          2. `directives[0]` is the reply's TRAILING element: nothing but
             whitespace (and/or later fenced directive blocks, which are
             ALWAYS ignored anyway under v1's one-per-turn rule) follows
             its closing fence. A directive followed by more real prose
             ("...but I cannot actually run this for you") is presumed to
             be an EXAMPLE, not a request, and is never actionable --
             still stripped from the visible reply (never leaked raw
             either way), just never invoked.
        KNOWN v1 LIMITATION (documented per round-1 review, recorded in
        docs/spec-deltas/508.md): in-band signalling inside the model's
        own free-text output is inherently ambiguous; this trailing-
        position heuristic is a cheap, mostly-effective mitigation, not a
        proof. It is a mechanical CHEAP filter, not model understanding --
        a sufficiently unusual reply shape can still misfire in either
        direction (e.g. a genuine request immediately followed by an
        unrelated trailing remark is currently never actionable)."""
    reply_text = reply_text or ""
    directives = []
    matches = list(_CAPABILITY_DIRECTIVE_RE.finditer(reply_text))

    pieces = []
    cursor = 0
    for m in matches:
        pieces.append(reply_text[cursor:m.start()])
        directives.append(_parse_one_directive(m.group(1)))
        cursor = m.end()
    pieces.append(reply_text[cursor:])
    remainder = "".join(pieces)

    dangling = _CAPABILITY_DANGLING_OPEN_RE.search(remainder)
    if dangling:
        directives.append(CapabilityDirectiveError(
            raw=remainder[dangling.start():], reason="unterminated fence (no closing marker found)"))
        remainder = remainder[:dangling.start()] + remainder[dangling.end():]

    visible = re.sub(r"\n{3,}", "\n\n", remainder).strip()

    actionable = None
    if matches and isinstance(directives[0], CapabilityDirective):
        tail_parts = []
        cursor = matches[0].end()
        for m in matches[1:]:
            tail_parts.append(reply_text[cursor:m.start()])
            cursor = m.end()
        tail_parts.append(reply_text[cursor:])
        if not "".join(tail_parts).strip():
            actionable = directives[0]

    return visible, directives, actionable


# #508 design point 2: "cap result size injected -- truncate with a
# marker, never unbounded". Char cap on the RENDERED result text handed to
# the same-turn follow-up completion.
CAPABILITY_RESULT_CHAR_CAP = 4000


def render_capability_result_text(invoke_result, cap_chars=CAPABILITY_RESULT_CHAR_CAP):
    """Renders an `adapters.InvokeResult` (argv flavor) or
    `adapters.McpInvokeResult` (mcp flavor) into plain text for the
    same-turn follow-up completion (docs/spec-deltas/508.md #2), then
    hard-truncates to `cap_chars` -- never unbounded, and never SILENTLY:
    a truncated result has an explicit `"... [truncated N chars]"` marker
    appended, itself counted within `cap_chars` (the returned text never
    exceeds the cap, marker included). This is a hand-rolled cap-and-mark
    rather than a reuse of `_truncate_chars` (that helper's contract is
    "slice, no marker" -- every OTHER caller in this module reports
    truncation only via `budget_report`'s `clipped_components`, which has
    no equivalent for a same-turn adapter completion; the model itself
    needs to SEE that a result was cut, in-band, since there is no
    separate side-channel here).

    Duck-typed on shape rather than `isinstance` against adapters.py's
    namedtuples (this module has no import-time dependency on which
    invoke flavor produced the result): an `McpInvokeResult` carries a
    `result` field (the JSON-RPC response's already-extracted `result`
    object) that an `InvokeResult` does not."""
    if hasattr(invoke_result, "result"):
        try:
            body = json.dumps(invoke_result.result, sort_keys=True, indent=2)
        except (TypeError, ValueError):
            body = str(invoke_result.result)
        raw = "mcp tool result:\n%s" % body
    else:
        parts = ["exit code: %s" % invoke_result.returncode]
        if invoke_result.stdout:
            parts.append("stdout:\n%s" % invoke_result.stdout)
        if invoke_result.stderr:
            parts.append("stderr:\n%s" % invoke_result.stderr)
        raw = "\n".join(parts)
    if len(raw) <= cap_chars:
        return raw, False
    marker = "... [truncated %d chars]" % (len(raw) - cap_chars)
    keep = max(0, cap_chars - len(marker))
    return raw[:keep] + marker, True


def render_capability_result_followup(context_for_adapter, capability_name, result_text):
    """Builds the SAME-turn follow-up completion's context (docs/spec-
    deltas/508.md #2, design doc sequence 2): reuses the ORIGINAL turn's
    already-composed `system` prompt VERBATIM (persona + roster + recalled
    notes + summary were already composed exactly once for this turn --
    Sec9.1/Sec17.7: recall runs at most once per turn, this function never
    triggers a second compose/recall pass) and builds a fresh `input`
    that hands the model the capability's result to synthesize its final,
    user-facing reply from. Any OTHER adapter-relevant key in
    `context_for_adapter` (e.g. `model`, `fileOutputDir`) survives
    unchanged into the returned dict -- this is a shallow copy plus two
    field overrides (`system` restated for clarity, `input` replaced),
    never a from-scratch context."""
    system = (context_for_adapter or {}).get("system", "")
    original_input = (context_for_adapter or {}).get("input", "")
    input_text = (
        "%s\n\n[capability %r result]\n%s\n\nUsing the result above, write your "
        "final reply to the user now, in plain language. Do not include another "
        "capability request block unless a second, genuinely different action "
        "is truly required -- only the FIRST capability request per turn is "
        "ever honored." % (original_input, capability_name, result_text)
    )
    followup = dict(context_for_adapter or {})
    followup["system"] = system
    followup["input"] = input_text
    return followup


def render_capability_completed_fallback(capability_name, result_text):
    """#508 round-1 review, findings 4/5: a template reply for when the
    same-turn follow-up completion cannot supply a usable final reply --
    either because the follow-up `complete_fn` call itself raised (the
    capability ALREADY ran; losing that outcome entirely, and inviting a
    retry that would re-run it, is worse than a rougher templated reply),
    or because the follow-up's OWN reply stripped down to nothing (e.g.
    the model's follow-up was itself just another directive block, with
    no surrounding prose). Either way, the capability genuinely completed
    and its result is genuinely known -- this states that plainly rather
    than returning a blank or dropping the turn's outcome on the floor."""
    return "%s completed. Result:\n%s" % (capability_name, result_text)


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


# #508 design point 1: the roster prompt text is what TEACHES the model
# the directive syntax -- an explicit request is the signal that fires in
# embedding mode, not a similarity score, so the model has to actually be
# told the exact shape once, every turn a real capability is on offer.
# Built from _CAPABILITY_FENCE_TOKEN (chr(96)-based, see that constant's
# own docstring for why) rather than a literal backtick sequence.
_CAPABILITY_DIRECTIVE_TEACHING_LINES = (
    "To use one of the capabilities above right now, reply with exactly "
    "one fenced block, at most, shaped like this:",
    _CAPABILITY_FENCE_TOKEN + CAPABILITY_DIRECTIVE_FENCE_LANG,
    '{"name": "<capability-name>", "params": {...}}',
    _CAPABILITY_FENCE_TOKEN,
    "Only include this block when you actually intend to invoke that "
    "capability right now -- never as an example, and never more than one "
    "per reply. The block itself is never shown to the user; only invoke "
    "a capability that was actually listed above as available. "
    # #508 round-2 review, NEW-MEDIUM: this rule is ENFORCED by the parser
    # (turns.parse_capability_directives's trailing-position `actionable`
    # check) but was never TAUGHT -- an ordinary "Let me check...
    # [block]... One moment!" reply used to silently do nothing while its
    # visible text told the user an action was underway. Stated explicitly
    # so the model puts any explanation BEFORE the block, never after it.
    "The block must be the LAST thing in your reply -- put any explanation "
    "BEFORE it, never after: if you say anything more once the block ends, "
    "it will not be treated as a real request.",
)


def _render_roster_entries(entries):
    """Renders `roster_provider()`'s entry dicts into system-prompt lines.

    AST-062 (SPEC-ASSISTANT.md Sec11.4, issue #337): "never present an
    unavailable ability as usable" -- an entry with `available` falsy
    renders its `reason` (`unavailable_reason` from the compiled
    CapabilityIndexEntry, threaded through by engine.py's
    `_roster_provider_for`) inline, so the persona's own system context
    states WHY a plausible-looking capability can't be used right now,
    never just a bare "(unavailable)" tag a model could talk past.

    #508: appends the directive-syntax TEACHING block (see
    `_CAPABILITY_DIRECTIVE_TEACHING_LINES`) whenever `entries` contains at
    least one REAL, named capability -- i.e. NOT the empty-roster
    placeholder shape (nothing to invoke) and NOT ONLY the `(ambiguous)`
    sentinel `_roster_provider_for` synthesizes for `AskInsteadOfGuess`
    (that sentinel's own one-liner already instructs "ask before using any
    capability" -- teaching invoke syntax alongside it would contradict
    that instruction). An entry list that mixes the sentinel with real
    entries (not a shape `_roster_provider_for` currently produces, but not
    excluded by this function either) still teaches the syntax, since real,
    named candidates are genuinely present to invoke."""
    if not entries:
        return ["(no roster entries -- capability roster compilation lands in AST-061/E6)"]
    lines = ["Available capabilities:"]
    real_entries = False
    for entry in entries:
        name = entry.get("name", "?")
        if name != "(ambiguous)":
            real_entries = True
        one_liner = entry.get("one-liner") or entry.get("one_liner") or ""
        if entry.get("available"):
            lines.append("- %s (available): %s" % (name, one_liner))
        else:
            reason = entry.get("reason") or entry.get("unavailable_reason")
            suffix = " -- %s" % reason if reason else ""
            lines.append("- %s (unavailable%s): %s" % (name, suffix, one_liner))
    if real_entries:
        lines.extend(_CAPABILITY_DIRECTIVE_TEACHING_LINES)
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
    # File output (2026-07-29, human-directed): when the engine resolved a
    # sanctioned output directory (`_fileOutputDir`, injected per-turn by
    # _chat -- never persisted config), the adapter gets it (to scope-open
    # the CLI's Write tool) and the system prompt states the ABSOLUTE path
    # plus the relative link form the chat renderer resolves. Appended
    # AFTER the budget accounting: a fixed ~2-line suffix, never clipped.
    # Temporal grounding (2026-07-29, human-directed): the engine injects
    # the formatted wall clock per-turn as `_nowText` (never computed here,
    # so hermetic compose tests stay deterministic); when present the
    # assistant always knows the current date/time/weekday/timezone.
    now_text = (persona_cfg or {}).get("_nowText")
    if now_text:
        context_for_adapter["system"] = (
            context_for_adapter["system"] + "\n\nCurrent date & time: " + now_text)
    file_output_dir = (persona_cfg or {}).get("_fileOutputDir")
    if file_output_dir:
        context_for_adapter["fileOutputDir"] = file_output_dir
        context_for_adapter["system"] = (
            context_for_adapter["system"]
            + "\n\nFile output: you CAN create files. Write them with your "
            + "Write tool as PLAIN FILENAMES in your current working directory "
            + "(it is writable); after your reply they are published to the "
            + "user's media library automatically. Link each produced file in "
            + "your reply as [name](media/chat/<filename>) or "
            + "![alt](media/chat/<filename>) so it renders inline in the chat. "
            + "Never claim the workspace is read-only without an actual failed write."
        )

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


def _merge_usage(first, second):
    """#508 round-1 review (LOW finding 7): a hook-driven same-turn
    follow-up completion (`on_reply`) is a SECOND real adapter call --
    its token usage is real spend, not a replacement for the first
    completion's. AGGREGATES rather than overwrites: every numeric field
    present in BOTH dicts is SUMMED (e.g. `input_tokens`/`output_tokens`);
    a field present in only one side, or not itself numeric on both
    sides, is carried through from whichever side has it (`second` wins
    on a genuine conflict -- the more complete/final report). `None` on
    either side degrades to returning the other side unchanged (never a
    crash, never a fabricated total from a missing report)."""
    if first is None:
        return second
    if second is None:
        return first
    if not isinstance(first, dict) or not isinstance(second, dict):
        return second
    merged = dict(first)
    for key, value in second.items():
        prior = merged.get(key)
        if (isinstance(value, (int, float)) and not isinstance(value, bool)
                and isinstance(prior, (int, float)) and not isinstance(prior, bool)):
            merged[key] = prior + value
        else:
            merged[key] = value
    return merged


def run_turn(persona_cfg, roster_provider, recall_fn, session_state, user_message,
             *, budgets=None, cache=None, summarizer=None,
             get_adapter=adapters.get_adapter, adapter_kwargs=None,
             refresh_every=SUMMARY_REFRESH_EVERY_K_TURNS, on_reply=None):
    """Runs one turn: compose -> adapter.complete -> [on_reply] -> advance
    session_state.

    Returns {"text", "chips", "usage", "timings", "updated_session_state"}
    (Sec8.1's adapter shape plus chips + session_state) with an additive
    "budget_report" key for callers (E2's overlay, debugging) that want it.

    `on_reply` (#508, optional, `None` by default -- every pre-#508 caller
    is unaffected): a callable `on_reply(first_text, context_for_adapter,
    complete_fn, adapter_kwargs) -> {"text"?, "usage"?, "timings"?} | None`
    invoked, when given, EXACTLY ONCE per turn, immediately after the
    FIRST completion returns. This is the seam a caller (engine.py) uses
    to drive a same-turn, same-session-context follow-up completion (e.g.
    after invoking a capability the model's first reply requested) WITHOUT
    this module having to know anything about capabilities, directives, or
    adapters.py's invoke primitives -- `compose_context` still runs
    EXACTLY ONCE (Sec9.1/Sec17.7: recall never runs twice for one user
    message), and `on_reply` receives the ALREADY-COMPOSED context so it
    can reuse the same system prompt for a second `complete_fn` call of
    its own choosing (or none at all).

    A `None` return (or no `on_reply` at all) leaves the first
    completion's `text`/`usage`/`timings` completely untouched -- this
    keeps the DEFAULT turn shape (ordinary chat, most of the time) exactly
    as fast and simple as before this parameter existed: one adapter call,
    one session_state advance, nothing else. A dict return REPLACES
    `text`/`timings` with whatever it supplies (falling back to the first
    completion's own value for anything it omits), but MERGES `usage` via
    `_merge_usage` rather than replacing it outright (round-1 review
    finding 7: a hook that drives a real second adapter call spends real
    tokens on TOP of the first call, so the turn's reported usage must
    reflect both, not just the last one reported) -- a hook that never
    supplies `usage` at all (e.g. a gap refusal or a validation error,
    where no second completion ever ran) leaves the first completion's
    own usage completely untouched, exactly as before this fix.
    `session_state` always advances with the FINAL text (post-hook),
    never the first completion's raw text, so a hook that drives a second
    completion never lets a stale/pre-invocation reply leak into the
    durable transcript."""
    resolved = _resolve_budgets(budgets)
    composed = compose_context(persona_cfg, roster_provider, recall_fn,
                                session_state, user_message, budgets, cache=cache)

    provider = ((persona_cfg or {}).get("llm") or {}).get("provider")
    complete_fn = get_adapter(provider)
    result = complete_fn(composed["context_for_adapter"], **(adapter_kwargs or {}))

    text = result.get("text", "")
    usage = result.get("usage")
    timings = result.get("timings")

    if on_reply is not None:
        outcome = on_reply(text, composed["context_for_adapter"], complete_fn, adapter_kwargs)
        if outcome is not None:
            text = outcome.get("text", text)
            if "usage" in outcome:
                usage = _merge_usage(usage, outcome["usage"])
            timings = outcome.get("timings", timings)

    updated_state = _advance_session_state(
        session_state or {}, user_message, text,
        summarizer or default_summarizer, refresh_every,
        _cap_chars(resolved, "summary"))

    return {
        "text": text,
        "chips": composed["chips"],
        "usage": usage,
        "timings": timings,
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
