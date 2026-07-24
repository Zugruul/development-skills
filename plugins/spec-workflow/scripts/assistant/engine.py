"""AssistantEngine -- route table + worker-thread lifecycle owner
(SPEC-ASSISTANT.md §5a, AST-010, issue #308).

Per §5a the engine is the ONE thing neural-view.py mounts for `/assistant/*`:
neural-view.py's Handler delegates any such path to `AssistantEngine.handle()`
and otherwise stays untouched -- no request-handling logic for the assistant
lives in neural-view.py itself. `AssistantEngine` owns:

  - a route table (`handle(method, path, query, body)`) dispatched by an
    HTTP request thread; the request thread only enqueues work and reads
    already-computed state, per §5a's cross-thread rule below;
  - one long-lived worker thread per subsystem (distiller, tasks, traces,
    index), each in the `workers` registry as (name, Thread, stop_event) so
    tests can assert clean start/stop without an HTTP server. v1 (AST-010)
    workers are no-op heartbeats parked on `stop_event.wait()` -- the real
    per-subsystem loops arrive with their own tasks (distiller: E3,
    traces/index: E4/E6) and replace the worker body without touching this
    registry's shape;
  - a `queue.Queue` per subsystem (`queues[name]`), created now so HTTP
    request threads can enqueue-only into it later without the signature
    churning when the real workers land -- nothing drains these queues yet.

Isolation (§17.1): constructing/starting/stopping an engine never imports a
provider CLI and never spawns a subprocess -- `/assistant/status` in
particular must stay subprocess-free.

`start()`/`stop()` are both idempotent: `start()` on an already-started
engine is a no-op, and `stop()` may be called more than once (e.g. once from
an explicit shutdown path and once via `atexit`) without raising.
"""
import os
import queue
import threading

from assistant import adapters, default_store, discovery, turns
from assistant.store import SessionStore

# The four §5a-mandated subsystem workers this skeleton wires up. Real logic
# lands per-subsystem in later E1/E3/E4/E6 tasks; AST-010 only creates the
# named slot (thread + stop_event + queue) each of those tasks plugs into.
WORKER_NAMES = ("distiller", "tasks", "traces", "index")

# AST-014 /assistant/history?n=N: default window + hard cap so a client
# cannot force an unbounded read of the transcript (SessionStore.history's
# tail-read is a full-file read at v1 -- see store.py's docstring).
HISTORY_DEFAULT_N = 20
HISTORY_MAX_N = 500


def _heartbeat_worker(stop_event):
    """v1 no-op worker body: parks on `stop_event` until told to stop. No
    busy loop, no polling interval -- `wait()` blocks until `set()` is
    called. Replaced by a real per-subsystem loop in a later task."""
    stop_event.wait()


def _main_name(section):
    """The main name (names[0]) of a candidate's `assistant:` section, or
    None if it somehow carries no names (should not happen for a
    `discovery.classify_repo` "candidate" -- `validate_assistant` already
    requires a non-empty `names` list -- but this stays defensive rather
    than indexing blind). Delegates the actual name list extraction to
    `default_store._names` (AST-021: one name/alias reading, matching the
    §7.6 resolution path's own view of a section's names) instead of
    re-parsing `section["names"]` a third time."""
    names = default_store._names(section)
    return names[0] if names else None


class AssistantEngine:
    """Owns the `/assistant/*` route table and the per-subsystem worker
    threads. One instance is constructed per server process (neural-view.py's
    `serve` branch) and started/stopped alongside the server's own
    lifecycle."""

    def __init__(self, repos_getter, state_dir):
        """`repos_getter` is a zero-arg callable returning the CURRENT
        (name, root) repo list at call time -- not a snapshot. neural-view.py
        passes `lambda: REPOS` so a marker added after boot and picked up by
        `rescan_loop`'s reassignment of the module-level REPOS (see
        neural-view.py's rescan_loop docstring) is reflected on the very next
        `/assistant/status` poll, instead of the engine forever counting
        against whatever REPOS held at construction time."""
        self._repos_getter = repos_getter
        self.state_dir = state_dir
        self.queues = {name: queue.Queue() for name in WORKER_NAMES}
        self.workers = []  # [(name, Thread, stop_event), ...] -- see start()
        self._lock = threading.Lock()
        # AST-016 review r1 BLOCKER fix: one lock per resolved assistant
        # root, guarding _chat's whole load_state -> run_turn -> save_state
        # critical section (see _chat_lock_for's docstring).
        self._chat_locks = {}
        self._chat_locks_guard = threading.Lock()
        # AST-021 (SPEC-ASSISTANT.md §7.2-§7.4, §17.9): startup selection
        # state, engine-instance memory only -- one process = one
        # selection, lost on restart by design (cross-tab/cross-restart
        # persistence is AST-022's selection MEMORY, out of scope here).
        # `_selected` is the chosen candidate's main name, or None before
        # any selection (or after Skip). `_gated` is set ONLY by an
        # explicit POST /assistant/skip (§7.3) -- it is deliberately NOT
        # derived from "_selected is None" alone, because the existing
        # §7.6 chat resolution path (terminal `--assistant NAME` / stored
        # local default, AST-016) must keep working unaffected by a
        # multi-candidate repo that simply hasn't had a startup pick made
        # yet (see section-assistant-terminal.sh's two-candidate coverage,
        # which never calls /assistant/select at all). `/assistant/status`
        # additionally folds in `outcome == "none"` for the page's benefit
        # (see _status's docstring) since that branch is already hard-
        # gated by having no assistant to resolve against.
        self._selected = None
        self._gated = False
        self._selection_lock = threading.Lock()

    def start(self):
        """Launch the worker registry. Idempotent: a second call while
        already started is a no-op (does not spawn duplicate workers)."""
        with self._lock:
            if self.workers:
                return
            workers = []
            for name in WORKER_NAMES:
                stop_event = threading.Event()
                thread = threading.Thread(
                    target=_heartbeat_worker,
                    args=(stop_event,),
                    name=f"assistant-{name}",
                    daemon=False,
                )
                thread.start()
                workers.append((name, thread, stop_event))
            self.workers = workers

    def stop(self, timeout=5.0):
        """Signal every worker's stop_event and join each with a bounded
        timeout, so a server shutdown never hangs on a stuck worker.
        Idempotent: safe to call again (or on an engine that was never
        started) -- a second call just finds nothing left to stop."""
        with self._lock:
            workers, self.workers = self.workers, []
        for _, _, stop_event in workers:
            stop_event.set()
        for _, thread, _ in workers:
            thread.join(timeout=timeout)

    # --- route table --------------------------------------------------------

    def handle(self, method, path, query=None, body=None):
        """Dispatch one `/assistant/*` request. `path` must already be
        confirmed by the caller to start with "/assistant/" (neural-view.py's
        Handler does this before delegating). Returns
        `(status, payload, content_type)` on a match, or `None` if nothing
        matched -- the caller is responsible for turning that into a 404."""
        if method == "GET" and path == "/assistant/status":
            return 200, self._status(), "application/json"
        if method == "GET" and path == "/assistant/history":
            return 200, self._history(query), "application/json"
        if method == "POST" and path == "/assistant/chat":
            return self._chat(body)
        if method == "POST" and path == "/assistant/select":
            return self._select(body)
        if method == "POST" and path == "/assistant/skip":
            return self._skip()
        return None

    def _status(self):
        """GET /assistant/status -- extended for AST-021 (SPEC-ASSISTANT.md
        §7.2-§7.4): carries the FULL scan result (`outcome`, `candidates`)
        so the page can branch on the exact same one/multiple/none
        classification `discovery.scan` computed, plus this engine
        instance's current selection state (`selected`, `gated`). `gated`
        is true when Skip was explicitly chosen (§7.3) OR when there is no
        assistant to select at all (`outcome == "none"`, §7.4) -- the page
        needs one boolean to decide whether to hard-gate voice/chat, it
        should not have to re-derive "none means gated" itself."""
        scan = discovery.scan(root for _, root in self._repos_getter())
        candidates_payload = [
            {
                "name": _main_name(section),
                "aliases": default_store._names(section)[1:],
                "root": str(root),
            }
            for root, section in scan.candidates
        ]
        return {
            "engine": "ok",
            "workers": [
                {"name": name, "alive": thread.is_alive()}
                for name, thread, _ in self.workers
            ],
            "assistants": len(scan.candidates),
            "outcome": scan.outcome,
            "candidates": candidates_payload,
            "selected": self._selected,
            "gated": self._gated or scan.outcome == "none",
        }

    def _select(self, body):
        """POST /assistant/select {"name": str} -> {"selected", "gated"}
        (§7.2/§7.3, AST-021). `name` is resolved case-insensitively against
        the CURRENT scan's candidates' names/aliases via
        `default_store._matches_name` -- the exact same matching rule the
        §7.6 chat resolution path already uses, so a candidate's alias list
        is interpreted identically everywhere rather than by two matchers
        that could drift apart. An unmatched/ambiguous name is a 404-style
        error listing the real candidates, never a crash or a silent
        no-op. Selecting always clears an earlier Skip (`_gated` -> False)
        -- picking an assistant un-gates voice/chat for the rest of this
        engine's process lifetime (session memory only; cross-tab/
        cross-restart persistence is AST-022, out of scope here)."""
        body = body if isinstance(body, dict) else {}
        name = body.get("name")
        if not isinstance(name, str) or not name.strip():
            return 400, {"error": "name is required"}, "application/json"

        scan = discovery.scan(root for _, root in self._repos_getter())
        matches = [
            section for _, section in scan.candidates
            if default_store._matches_name(section, name)
        ]
        candidate_names = sorted(
            n for _, section in scan.candidates
            for n in [_main_name(section)] if n
        )
        if not matches:
            return 404, {
                "error": f"no assistant named {name!r}",
                "candidates": candidate_names,
            }, "application/json"
        if len(matches) > 1:
            return 404, {
                "error": f"assistant name {name!r} is ambiguous",
                "candidates": candidate_names,
            }, "application/json"

        with self._selection_lock:
            self._selected = _main_name(matches[0])
            self._gated = False
        return 200, {"selected": self._selected, "gated": self._gated}, "application/json"

    def _skip(self):
        """POST /assistant/skip -> {"selected": null, "gated": true}
        (§7.3). Hard-gates chat (via `_chat`'s gate check below) for the
        rest of this engine's process lifetime, or until a later
        /assistant/select -- §17.9's "no assistant selected" invariant,
        made explicit rather than merely implied by `selected` staying
        null."""
        with self._selection_lock:
            self._selected = None
            self._gated = True
        return 200, {"selected": None, "gated": True}, "application/json"

    def _history(self, query):
        """GET /assistant/history?n=N -- last N exchanges of the resolved
        assistant's session transcript. The store is constructed FRESH on
        every call (never held on `self`) for the same reason `_status`
        re-discovers candidates every call: `self._repos_getter()` is a
        live getter, not a ctor-time snapshot (see __init__'s docstring),
        so a marker added/removed after boot must be reflected on the very
        next poll -- caching a store instance would pin it to whatever
        root resolved first and go stale exactly like a ctor-time repos
        snapshot would.
        """
        n = _parse_history_n(query)
        candidates = default_store.discover_candidates(
            root for _, root in self._repos_getter()
        )
        try:
            root, _section = default_store.resolve_assistant(candidates, state_dir=self.state_dir)
        except default_store.ResolutionError as exc:
            # No assistant unambiguously resolved (none discovered, or
            # multiple with no stored default) -- an empty, explained
            # result rather than a 404/500; §5a routes never crash on an
            # absent selection, matching /assistant/status's `selected:
            # None` treatment of the same not-yet-selected state.
            return {"exchanges": [], "warnings": [f"no assistant resolved: {exc}"]}
        return SessionStore(root).history(n)

    def _chat_lock_for(self, root):
        """One `threading.Lock` per resolved assistant root, canonicalized
        via `os.path.realpath` so two different-looking paths to the same
        repo (a symlink hop, a relative vs. absolute root) share the SAME
        lock instead of silently getting independent ones (the exact
        lock-key-canonicalize failure mode: a lock keyed on a raw, non-
        canonical string looks correct in the common case and only misses
        under path aliasing).

        Per §7.5 there is exactly one session per assistant (repo) -- two
        concurrent `/assistant/chat` requests against the SAME assistant
        MUST serialize (a turn is a load -> compose -> provider-call ->
        save read-modify-write against `session-state.json`; unlocked, the
        later save silently clobbers the earlier one -- reproduced live in
        review r1: 2 concurrent chats, transcript kept both exchanges
        [append-only, each write lands atomically] but session-state.json
        kept only one [read-modify-write, not append-only], turn_count
        stuck at 1 instead of 2). Two chats against DIFFERENT assistants
        must NOT block each other, hence per-root rather than one global
        lock. Creating a not-yet-seen root's Lock is itself guarded by a
        small top-level `_chat_locks_guard` (cheap dict mutation only --
        never held across a turn, so it is never the serialization
        bottleneck; the per-root lock returned here is what `_chat` holds
        across the actual turn)."""
        key = os.path.realpath(root)
        with self._chat_locks_guard:
            lock = self._chat_locks.get(key)
            if lock is None:
                lock = threading.Lock()
                self._chat_locks[key] = lock
            return lock

    def _chat(self, body):
        """POST /assistant/chat -- {"message": str, "assistant"?: str} ->
        {"text", "chips", "warnings"} (§7.6, §5, AST-016, issue #314). The
        ENGINE-CORE turn endpoint: §7.6 resolution (flag -> sole assistant
        -> local default -> error listing candidates, same order/errors as
        `_history` above and the terminal's own `--assistant`), then
        turns.run_turn against the resolved assistant's persona/provider,
        then a durable append + state save via SessionStore (§8.7) --
        exactly what both the terminal (this task) and the future overlay
        (E2) call. No worker-queue involvement: per §5a HTTP request
        threads execute turns directly, on the request thread.

        A resolution failure is a clean 4xx, never a turn attempt (§17.9:
        chat is hard-gated off with no assistant to run it against) --
        listing candidates exactly like `_history`'s ResolutionError
        handling and default_store.resolve_assistant's own message shape,
        so a terminal `--assistant <unknown>` error and this route's JSON
        error say the same thing.

        The load_state -> run_turn -> append_exchange -> save_state
        sequence runs under `_chat_lock_for(root)` (review r1 BLOCKER fix,
        see that method's docstring): concurrent turns against the SAME
        assistant are serialized -- correct per §7.5's one-session model --
        while turns against different assistants never block each other.

        AST-021 (§17.9): checked FIRST, before any resolution attempt -- an
        explicit POST /assistant/skip (`_gated`) refuses every chat with a
        specific gate error, distinct from an ordinary §7.6 resolution
        failure below. This does NOT fire merely because nothing has been
        selected yet (`_gated` defaults False) -- the terminal's own
        `--assistant NAME`/stored-default resolution (this same route,
        AST-016) must keep working unaffected by a multi-candidate repo
        that never called /assistant/select at all.
        """
        body = body if isinstance(body, dict) else {}
        if self._gated:
            return 403, {
                "error": "chat is gated off for this session (assistant "
                          "selection was skipped) -- see /assistant/select",
            }, "application/json"
        message = body.get("message")
        if not isinstance(message, str) or not message.strip():
            return 400, {"error": "message is required"}, "application/json"

        assistant_flag = body.get("assistant")
        candidates = default_store.discover_candidates(
            root for _, root in self._repos_getter()
        )
        try:
            root, section = default_store.resolve_assistant(
                candidates, flag=assistant_flag, state_dir=self.state_dir)
        except default_store.ResolutionError as exc:
            return 400, {"error": str(exc)}, "application/json"

        store = SessionStore(root)
        with self._chat_lock_for(root):
            session_state = store.load_state()
            try:
                result = turns.run_turn(section, None, None, session_state, message)
            except adapters.AdapterError as exc:
                # provider CLI failure (Sec8.5) -- a clean upstream error,
                # never a raw traceback, and never a persisted exchange
                # (nothing to append: the turn produced no reply).
                return 502, {"error": str(exc)}, "application/json"

            store.append_exchange(message, result["text"])
            store.save_state(result["updated_session_state"])

        warnings = []
        if result.get("budget_report", {}).get("over_budget"):
            warnings.append("turn context exceeded the token budget")

        return 200, {
            "text": result["text"],
            "chips": result["chips"],
            "warnings": warnings,
        }, "application/json"


def _parse_history_n(query):
    raw = None
    if query:
        values = query.get("n")
        if values:
            raw = values[0]
    if raw is None:
        return HISTORY_DEFAULT_N
    try:
        n = int(raw)
    except (TypeError, ValueError):
        return HISTORY_DEFAULT_N
    if n < 0:
        return 0
    return min(n, HISTORY_MAX_N)
