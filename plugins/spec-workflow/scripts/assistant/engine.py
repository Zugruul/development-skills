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
    workers were all no-op heartbeats parked on `stop_event.wait()`; AST-030
    replaces the `distiller` slot's body with the real batching loop
    (`distill.run_worker`) without touching this registry's shape. AST-066
    (SPEC-ASSISTANT.md Sec12.3) replaces the `tasks` slot's body the same
    way: `tasks.run_worker` drains the tasks queue, running each queued
    task's registered executor through the queued/started/progress/
    completed/failed state machine (every transition also a trace event
    via the traces queue -- see that module's docstring). AST-061
    (SPEC-ASSISTANT.md Sec11.3) replaces the `index` slot's body the same
    way: `capability_index.run_worker` compiles a per-root
    CapabilityIndex on start and recompiles on config/skill-set change
    (never per-turn -- see `_on_capability_index_compiled`/
    `capability_index_for` below for the lock-cheap snapshot read a turn
    actually uses);
  - a `queue.Queue` per subsystem (`queues[name]`), created now so HTTP
    request threads can enqueue-only into it later without the signature
    churning when the real workers land. AST-030 is the first to actually
    drain one: `_chat` enqueues a post-turn exchange-ref into
    `queues["distiller"]` (see `_enqueue_distill`), which is bounded
    (DISTILLER_QUEUE_MAXSIZE) unlike the other three, still-unused queues.

Isolation (§17.1): constructing/starting/stopping an engine never imports a
provider CLI and never spawns a subprocess -- `/assistant/status` in
particular must stay subprocess-free.

`start()`/`stop()` are both idempotent: `start()` on an already-started
engine is a no-op, and `stop()` may be called more than once (e.g. once from
an explicit shutdown path and once via `atexit`) without raising.
"""
import os
import queue
import sqlite3
import sys
import threading
import uuid
from datetime import datetime, timezone

from assistant import (adapters, artifacts, capability_index, default_store, digest as digest_module,
                        discovery, distill, harness, observability, selection_store, tasks, turns)
from assistant.store import SessionStore


def _now_iso():
    return datetime.now(timezone.utc).isoformat()

# The four §5a-mandated subsystem workers this skeleton wires up. Real logic
# lands per-subsystem in later E1/E3/E4/E6 tasks; AST-010 only creates the
# named slot (thread + stop_event + queue) each of those tasks plugs into.
WORKER_NAMES = ("distiller", "tasks", "traces", "index")

# AST-051 (SPEC-ASSISTANT.md §13.3): the kinds POST /assistant/voice-event
# accepts. TTS spans (tts-start/tts-end) are included so AST-050's speak
# path can reuse this SAME bridge route rather than growing a second one --
# this task only ever posts stt-start/stt-end itself.
_VOICE_EVENT_KINDS = frozenset({"stt-start", "stt-end", "tts-start", "tts-end"})

# AST-014 /assistant/history?n=N: default window + hard cap so a client
# cannot force an unbounded read of the transcript (SessionStore.history's
# tail-read is a full-file read at v1 -- see store.py's docstring).
HISTORY_DEFAULT_N = 20
HISTORY_MAX_N = 500

# AST-043 (SPEC-ASSISTANT.md Sec10.5, issue #329): GET /assistant/traces?
# limit=N -- default window + hard cap, same "bounded read, never an
# unbounded one" rationale as HISTORY_DEFAULT_N/HISTORY_MAX_N above (this
# is the traces-table analogue of that same guard).
TRACES_DEFAULT_LIMIT = 200
TRACES_MAX_LIMIT = 1000

# AST-066 (SPEC-ASSISTANT.md §12.3/§12.5, issue #341): GET /assistant/tasks?
# limit=N -- same "bounded read" rationale as TRACES_DEFAULT_LIMIT/
# TRACES_MAX_LIMIT above, for the queue-indicator's own read path.
TASKS_DEFAULT_LIMIT = 50
TASKS_MAX_LIMIT = 500

# AST-030 (SPEC-ASSISTANT.md Sec9.2/Sec9.5): the distiller queue is bounded
# so a stalled/slow distiller worker can never grow unbounded memory off a
# long-running chat session. Overflow policy is DROP-OLDEST: when full, the
# oldest queued exchange-ref is evicted to make room for the newest one --
# distillation favors recency over an unbounded backlog, and dropping a ref
# never loses the exchange itself (SessionStore.append_exchange already
# fsync'd it to session.jsonl before _enqueue_distill is ever called; only
# that one exchange's contribution to a future batch is skipped, not the
# turn). See `_enqueue_distill`.
DISTILLER_QUEUE_MAXSIZE = 1000

# issue #390: the traces queue was left unbounded (only the distiller's
# queue was ever bounded per AST-030) -- a stalled/slow traces writer thread
# could otherwise grow unbounded memory off a long-running chat session the
# exact same way an unbounded distiller queue could. Mirrors
# DISTILLER_QUEUE_MAXSIZE's value; the eviction posture on overflow is
# DIFFERENT from the distiller's drop-OLDEST policy, though -- traces are an
# ordered, append-only correlation log (seq is assigned in arrival order by
# the single writer thread), so silently reordering it via an evict-and-
# reinsert would corrupt that ordering. `observability.emit`'s existing
# `except queue.Full` branch (drop the NEWEST event, one stderr line) is the
# enforced policy here instead -- that branch already existed for exactly
# this case but was dead code in production while this queue stayed
# unbounded (a `Queue()` with no maxsize can never raise `Full`).
TRACES_QUEUE_MAXSIZE = 1000

# AST-061 (SPEC-ASSISTANT.md Sec11.3): per-turn roster hard cap. Same
# constant `_roster_provider_for` passes to `capability_index.roster_for_turn`
# for every root -- a single, documented default rather than a per-call
# magic number.
ROSTER_TOP_N = capability_index.DEFAULT_ROSTER_TOP_N

# #508 (SPEC-ASSISTANT.md Sec9.4/Sec9.5, design point 2 "bounded timeout"):
# the mandatory timeout an INLINE (synchronous, request-thread-blocking)
# capability invocation gets -- distinct from `adapters.
# DEFAULT_TIMEOUT_SECONDS` (60s, the provider-CLI adapter's own timeout):
# an invoked capability's own subprocess is a different kind of call than
# an LLM completion, and this bounds how long ONE HTTP request thread can
# be tied up per turn (Sec9.5: the TURN never blocks on the distiller/
# index/task queue, but an inline invoke is explicitly synchronous within
# the turn itself -- this constant is that invariant's actual bound). A
# bare module-level constant (not a per-call parameter) so tests can
# monkeypatch it down, same posture `section-assistant-engine.sh` already
# uses for other module-level knobs.
CAPABILITY_INVOKE_TIMEOUT_SECONDS = 30

# #508 round-1 review, HIGH finding 1: a QUEUED (longRunning) capability
# runs on the tasks worker thread, never the HTTP request thread -- there
# is no request thread left to protect, so reusing the 30s INLINE bound
# above was simply wrong: it silently killed a task the user had already
# been told was "safely queued", with the failure never reaching the
# conversation at all (a live bug the reviewer reproduced). This is a
# SEPARATE, deliberately more generous bound for the queued path only,
# matching `harness.DEFAULT_HARNESS_TIMEOUT_SECONDS` (300s) -- the SAME
# default this codebase already uses for its OTHER async-task mechanism
# (dispatched harness jobs), for exactly the same reason: background work
# has no request thread to bound, but the tasks worker is a SINGLE SERIAL
# thread (tasks.py's own documented execution model) that a genuinely
# hung subprocess would otherwise block forever, starving every other
# queued task (harness jobs included) behind it -- so a bound still
# exists, just a much longer one than the inline path's.
CAPABILITY_TASK_TIMEOUT_SECONDS = 300


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


def _candidate_llm(section):
    """A candidate's `llm` sub-mapping, resolved for the /assistant/status
    payload (#492): `{"provider": str|None, "model": str|None}`, degrading
    each field to None on any malformed shape rather than raising -- a
    `discovery.scan` "candidate" classification already requires
    `assistant.config.validate_assistant` to accept `llm.provider`/
    `llm.model` as strings (§6.5), so this defensive path should be
    unreachable in practice, but `_status` must never KeyError building the
    chat header's model name off a hand-crafted or corrupted section."""
    llm = section.get("llm") if isinstance(section, dict) else None
    if not isinstance(llm, dict):
        return {"provider": None, "model": None}
    provider = llm.get("provider")
    model = llm.get("model")
    return {
        "provider": provider if isinstance(provider, str) else None,
        "model": model if isinstance(model, str) else None,
    }


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
        # AST-030: the distiller's queue is bounded -- see
        # DISTILLER_QUEUE_MAXSIZE's docstring for the overflow policy.
        # "index" stays an unbounded no-op placeholder (AST-061's worker
        # never drains a queue of its own). "tasks" (AST-066, issue #341)
        # is DELIBERATELY LEFT UNBOUNDED even though it now has a real
        # worker: tasks.sqlite is a MUST-SURVIVE store (tasks.py's own
        # docstring), and a bounded queue's drop-on-full path means
        # `tasks.enqueue` returning a task_id with NO row ever created for
        # it (round-2 review, issue #341) -- `enqueue` already returns
        # `None` instead of a phantom id on that path, but bounding this
        # queue is still a real, load-bearing decision a future task
        # would need to make deliberately, not inherit by accident.
        self.queues["distiller"] = queue.Queue(maxsize=DISTILLER_QUEUE_MAXSIZE)
        # issue #390: bounded the same way -- see TRACES_QUEUE_MAXSIZE's
        # docstring for why the OVERFLOW POLICY differs from the
        # distiller's (drop-newest via observability.emit's existing `Full`
        # branch, not drop-oldest).
        self.queues["traces"] = queue.Queue(maxsize=TRACES_QUEUE_MAXSIZE)
        self.workers = []  # [(name, Thread, stop_event), ...] -- see start()
        self._lock = threading.Lock()
        # AST-016 review r1 BLOCKER fix: one lock per resolved assistant
        # root, guarding _chat's whole load_state -> run_turn -> save_state
        # critical section (see _chat_lock_for's docstring).
        self._chat_locks = {}
        self._chat_locks_guard = threading.Lock()
        # AST-021 (SPEC-ASSISTANT.md §7.2-§7.4, §17.9): startup selection
        # state. `_selected` is the chosen candidate's main name, or None
        # before any selection (or after Skip). `_gated` is set ONLY by an
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
        #
        # AST-022 (§7.5): the selection is no longer engine-instance memory
        # only -- it is loaded from `selection_store` (a JSON file under
        # `state_dir`, DISTINCT from `default_store`'s §6.3 machine-local
        # default name -- see selection_store's module docstring for the
        # two mechanisms' split) on every construction and persisted on
        # every `/assistant/select` / `/assistant/skip` / settings change,
        # so a second engine (page reload, second tab, a restarted
        # `neural-view.py`) over the SAME state dir picks up the SAME
        # choice. `_ask_again` is the persisted "ask again on load"
        # setting (§7.5's page toggle): when true, THIS boot's `_selected`
        # is forced back to None (a fresh pick is required every load) even
        # though a prior selection is still on disk -- but the flag itself
        # keeps persisting, so it stays on across restarts until the user
        # turns it off. `_gated` is likewise reset to False on an
        # askAgain=true boot: nothing has been explicitly Skipped yet this
        # boot, so the same "not gated before any selection" rule AST-021
        # already applies to a first-ever boot applies here too.
        loaded = selection_store.load(state_dir)
        self._ask_again = loaded["askAgain"]
        if self._ask_again:
            self._selected = None
            self._gated = False
        else:
            self._selected = loaded["selected"]
            self._gated = loaded["gated"]
        # AST-024 (SPEC-ASSISTANT.md §7.7/§7.8, issue #321): `lastActive`
        # is loaded regardless of `_ask_again` -- unlike `_selected`/
        # `_gated` (which askAgain=true deliberately resets so the picker
        # re-shows), an assistant's activation-history bookkeeping is not
        # part of "what was picked this boot" and must survive an
        # askAgain=true boot untouched, or its very first digest after
        # such a boot would wrongly look like "never active before".
        self._last_active = loaded["lastActive"]
        self._selection_lock = threading.Lock()
        # AST-042 (SPEC-ASSISTANT.md Sec10.4, issue #328): the shared
        # Prometheus exposition server, if any root currently enables it --
        # see start()/stop() and _discover_metrics_configs' docstrings.
        # None/None until (and unless) start() actually binds one.
        self._metrics_server = None
        self._metrics_thread = None
        # AST-061 (Sec11.3): per-root compiled CapabilityIndex snapshots,
        # written ONLY by the `index` worker thread's `on_compile` callback
        # (`_on_capability_index_compiled`) and read by `capability_index_for`
        # under the SAME short-held lock -- a plain dict-get/dict-set, never
        # held across a compile or a turn, so a per-turn roster read stays
        # lock-cheap (Sec17: never blocks on index refresh). Keyed by
        # `os.path.realpath(root)`, same canonicalization `_chat_lock_for`
        # already uses.
        self._capability_indices = {}
        self._capability_indices_lock = threading.Lock()

    def _retention_config_for(self, root):
        """AST-041 (SPEC-ASSISTANT.md §10.3, issue #327): per-root
        `observability.traces` retention knobs, for the traces worker's
        periodic prune pass (`observability.run_writer`'s `retention_config`
        callable). Reuses `discovery.classify_repo` -- the same parse
        (project.yaml) + validate (`config.validate_assistant`) path
        `_status`/`_chat` already resolve a root's `assistant:` section
        through -- rather than re-reading project.yaml itself, so this
        stays in lockstep with whatever counts as a valid section elsewhere
        in the engine.

        Returns the raw `observability.traces.sqlite` mapping (§6's example:
        `traces: {sqlite: {enabled, retainDays, maxMB}}` -- `config.py`'s
        `_check_observability_group` validates `traces` as a group of named
        backends, `sqlite` being the only one this epic defines; may be
        `{}` or contain only some of `enabled`/`retainDays`/`maxMB`), or
        `None` for any root that is not currently a `candidate` (no marker/
        config/section, or an invalid section) or that has no
        `observability.traces.sqlite` entry at all.
        `observability._resolve_retention` treats `None` (and a mapping
        missing either key) as "apply the §10.3 defaults (30/500)", never
        as "skip retention" -- this method's only job is surfacing
        whatever config exists, not deciding defaults."""
        try:
            classification = discovery.classify_repo(root)
        except Exception:
            return None
        section = classification.section if classification.kind == "candidate" else None
        if not section:
            return None
        traces = (section.get("observability") or {}).get("traces") or {}
        return traces.get("sqlite")

    def _metrics_config_for(self, root):
        """AST-042 (SPEC-ASSISTANT.md Sec10.4, issue #328): per-root
        `observability.metrics.prometheus` config -- `_retention_config_for`'s
        twin for the metrics group instead of traces (same
        `discovery.classify_repo` reuse, same `None`-for-"not a valid
        candidate or no entry" contract; see that method's docstring for
        why classify_repo is reused rather than re-parsing project.yaml).
        Returns the raw `{enabled, host, port}` mapping (may be `{}` or
        partial -- `_discover_metrics_configs` applies the Sec10.4/§6
        defaults, this method only surfaces what config exists), or `None`.
        """
        try:
            classification = discovery.classify_repo(root)
        except Exception:
            return None
        section = classification.section if classification.kind == "candidate" else None
        if not section:
            return None
        metrics = (section.get("observability") or {}).get("metrics") or {}
        return metrics.get("prometheus")

    def _discover_metrics_configs(self):
        """AST-042: every currently-discovered root (via `self._repos_getter()`,
        in that order) with `observability.metrics.prometheus.enabled: true`,
        as `[(root, host, port), ...]` with the Sec10.4/§6 defaults
        (`observability.DEFAULT_METRICS_HOST`/`DEFAULT_METRICS_PORT`, i.e.
        127.0.0.1:9464) already applied to any entry that omits `host`/
        `port`. Called ONLY from `start()` (see that method's docstring for
        why host/port is resolved once at start time rather than per
        scrape -- a bound TCP socket cannot silently rebind if config
        changes later)."""
        out = []
        for _repo_name, root in self._repos_getter():
            cfg = self._metrics_config_for(root)
            if cfg and cfg.get("enabled"):
                host = cfg.get("host") or observability.DEFAULT_METRICS_HOST
                port = cfg.get("port") or observability.DEFAULT_METRICS_PORT
                out.append((root, host, port))
        return out

    def _metrics_roots_provider(self):
        """AST-042: passed to `observability.start_metrics_server` as its
        `roots_provider` -- called fresh on EVERY `/metrics` scrape (never
        cached across calls, matching `_status`'s own live-`repos_getter`
        posture), so a root's `observability.metrics.prometheus.enabled`
        flag flipping off/on, or a new assistant appearing, is reflected on
        the very next scrape without an engine restart. This is
        DELIBERATELY independent of which root's host/port the shared
        server happens to be bound to (`_discover_metrics_configs`, called
        only at `start()`) -- v1's "share one server" choice (design doc)
        means the BOUND address is fixed for the server's lifetime, but
        WHICH roots' metrics that one server renders is still live.

        Returns `[(label, root), ...]` -- `label` is the assistant's main
        name (falls back to the raw root path, defensively, for a
        classify_repo call that somehow returns a candidate with no
        resolvable name -- should not happen, `_main_name` already has its
        own equally-defensive fallback)."""
        pairs = []
        for _repo_name, root in self._repos_getter():
            cfg = self._metrics_config_for(root)
            if not cfg or not cfg.get("enabled"):
                continue
            try:
                classification = discovery.classify_repo(root)
                label = _main_name(classification.section) if classification.kind == "candidate" else None
            except Exception:
                label = None
            pairs.append((label or root, root))
        return pairs

    def _on_capability_index_compiled(self, root, index):
        """AST-061: `capability_index.run_worker`'s `on_compile` callback --
        called from the `index` WORKER thread only, never an HTTP request
        thread. The lock is held only across this dict-set (cheap, never
        across the compile itself, which already happened before this
        call), matching `_chat_lock_for`'s own "lock only the mutation,
        never the slow part" discipline."""
        key = os.path.realpath(root)
        with self._capability_indices_lock:
            self._capability_indices[key] = index

    def capability_index_for(self, root):
        """AST-061: a lock-cheap READ of whatever the `index` worker has
        most recently compiled for `root` -- never compiles, never does
        I/O (Sec11.3/Sec17: a turn never blocks on index refresh). Returns
        an empty `CapabilityIndex` for a root the worker has not compiled
        yet (e.g. a brand-new root discovered between polls, or a chat
        request that races the very first compile pass) -- an empty
        roster degrades to `default_roster_provider`'s existing
        placeholder rendering in `turns.py`, never a crash."""
        key = os.path.realpath(root)
        with self._capability_indices_lock:
            index = self._capability_indices.get(key)
        return index if index is not None else capability_index.CapabilityIndex(entries=())

    def _roster_provider_for(self, root, user_message):
        """AST-061: builds the ZERO-ARG `roster_provider` closure
        `turns.compose_context` already calls (see turns.py's "roster seam"
        docstring -- `default_roster_provider` is the placeholder this
        replaces). Reads the already-compiled snapshot
        (`capability_index_for`, lock-cheap, no compute) and the per-turn
        query (`capability_index.embed_query`, degrading to keyword-only
        on any embeddings-capability failure, per that function's
        docstring), then scores via `roster_for_turn`.

        Turn contract (design doc's "the turn side of this task ends at
        roster injected + ambiguous -> the turn's reply asks"): a plain
        list of entries renders via `turns._render_roster_entries`'s
        `{"name", "one-liner", "available", "reason"}` shape (AST-062,
        issue #337, adds `reason` -- the compiled entry's
        `unavailable_reason` -- so an unavailable-but-enabled capability's
        SPECIFIC reason reaches the persona prompt, per Sec11.4's "never
        present an unavailable ability as usable"). An
        `AskInsteadOfGuess` sentinel is surfaced as ONE synthetic roster
        entry whose one-liner states the ambiguity -- this is a rendering
        choice, not a control-flow branch: the ambiguity note becomes part
        of the persona's own system context (same `roster_text` that
        already reaches the adapter), so the model's natural reply asks
        for clarification rather than this method silently picking a
        capability or short-circuiting the adapter call. Ordinary chat
        turns with no relevant capability at all (`roster_for_turn`
        returns `[]`, see its docstring) are completely unaffected --
        ambiguity only ever fires when there WAS a plausible, nonzero-
        relevance signal to be ambiguous about."""
        def _provider():
            index = self.capability_index_for(root)
            query = capability_index.embed_query(user_message)
            result = capability_index.roster_for_turn(index, query, ROSTER_TOP_N)
            if isinstance(result, capability_index.AskInsteadOfGuess):
                return [{
                    "name": "(ambiguous)",
                    "one-liner": f"ambiguous match ({result.reason}) -- ask before using any capability",
                    "available": False,
                }]
            return [
                {
                    "name": e.name,
                    "one-liner": e.one_liner,
                    "available": e.provisioned_ok,
                    "reason": e.unavailable_reason,
                }
                for e in result
            ]
        return _provider

    def start(self):
        """Launch the worker registry. Idempotent: a second call while
        already started is a no-op (does not spawn duplicate workers)."""
        with self._lock:
            if self.workers:
                return
            workers = []
            for name in WORKER_NAMES:
                stop_event = threading.Event()
                if name == "distiller":
                    # AST-030: the distiller slot runs the real batching
                    # loop instead of the v1 heartbeat no-op -- see
                    # distill.run_worker's docstring for the buffering/
                    # batch-trigger/failure posture this thread owns.
                    # AST-040: also hands it the traces queue so a batch's
                    # completion can emit a `distill.batch` trace event
                    # (enqueue-only, on this same worker thread).
                    thread = threading.Thread(
                        target=distill.run_worker,
                        args=(self.queues["distiller"], stop_event),
                        kwargs={"traces_queue": self.queues["traces"]},
                        name=f"assistant-{name}",
                        daemon=False,
                    )
                elif name == "index":
                    # AST-061 (SPEC-ASSISTANT.md Sec11.3): the index slot
                    # runs the real compile-on-start/compile-on-change loop
                    # instead of the v1 heartbeat no-op -- see
                    # capability_index.run_worker's docstring. `repos_getter`
                    # is passed straight through (same live-getter contract
                    # `__init__`'s docstring already documents for
                    # `_status`/`_history`); `on_compile` stores each
                    # (re)compiled snapshot into `self._capability_indices`
                    # under `_capability_indices_lock` -- the ONLY place that
                    # dict is ever written.
                    thread = threading.Thread(
                        target=capability_index.run_worker,
                        args=(self._repos_getter, stop_event),
                        kwargs={"on_compile": self._on_capability_index_compiled},
                        name=f"assistant-{name}",
                        daemon=False,
                    )
                elif name == "traces":
                    # AST-040 (SPEC-ASSISTANT.md §5a/§10.2): the traces
                    # slot runs the real single-writer traces.sqlite loop
                    # instead of the v1 heartbeat no-op -- see
                    # observability.run_writer's docstring. AST-041 (§10.3):
                    # also hands it `_retention_config_for` so the writer's
                    # own periodic prune pass resolves each root's
                    # observability.traces {retainDays, maxMB} instead of
                    # applying the 30/500 defaults to every root uniformly.
                    thread = threading.Thread(
                        target=observability.run_writer,
                        args=(self.queues["traces"], stop_event),
                        kwargs={"retention_config": self._retention_config_for},
                        name=f"assistant-{name}",
                        daemon=False,
                    )
                elif name == "tasks":
                    # AST-066 (SPEC-ASSISTANT.md §12.3, issue #341): the
                    # tasks slot runs the real single-writer tasks.sqlite
                    # queue/worker loop instead of the v1 heartbeat no-op --
                    # see tasks.run_worker's docstring. Hands it the traces
                    # queue (same reuse-not-a-second-writer pattern AST-040
                    # already gave the distiller slot) so every state
                    # transition also lands as a trace event.
                    # AST-067 (§12.4, issue #342): also hands it
                    # `self._repos_getter` (same live getter capability_index's
                    # own slot already takes) so `run_worker` can reconcile
                    # every currently-known root's leftover started/progress
                    # rows ONCE at startup -- see tasks.run_worker's docstring's
                    # "Restart reconciliation" section.
                    # AST-070 (§9.4, issue #345): registers harness.py's
                    # `run_harness_job`/`resolve_harness_job` under
                    # `harness.KIND` -- the FIRST real executor/resolver
                    # pair (both seams were deliberately empty through
                    # AST-066/067; this is what fills them). Every other
                    # kind still has no executor/resolver registered, so an
                    # unrelated enqueued kind still fails/orphans
                    # specifically and immediately, exactly as before.
                    # #508 (Sec9.4 sequence 3): also registers
                    # `capability_index.run_capability_invoke_task` under
                    # `capability_index.KIND` -- the executor a longRunning
                    # capability's queued invocation runs on this worker
                    # thread (never the chat/HTTP thread). No RESOLVER is
                    # registered for this kind: every capability-invoke task
                    # runs entirely in-process (never carries an
                    # `external_job_id`), so a row still `started`/
                    # `progress` at restart is genuinely unreconcilable --
                    # tasks.py's own restart-reconciliation logic already
                    # marks a no-`external_job_id` in-flight row `orphaned`,
                    # exactly the correct outcome for this local-only kind.
                    thread = threading.Thread(
                        target=tasks.run_worker,
                        args=(self.queues["tasks"], stop_event),
                        kwargs={
                            "traces_queue": self.queues["traces"],
                            "repos_getter": self._repos_getter,
                            "executors": {
                                harness.KIND: harness.run_harness_job,
                                capability_index.KIND: capability_index.run_capability_invoke_task,
                            },
                            "resolvers": {harness.KIND: harness.resolve_harness_job},
                        },
                        name=f"assistant-{name}",
                        daemon=False,
                    )
                else:
                    thread = threading.Thread(
                        target=_heartbeat_worker,
                        args=(stop_event,),
                        name=f"assistant-{name}",
                        daemon=False,
                    )
                thread.start()
                workers.append((name, thread, stop_event))
            self.workers = workers

            # AST-042 (SPEC-ASSISTANT.md Sec10.4, issue #328): mount the
            # shared Prometheus exposition server ONLY when at least one
            # currently-discovered root enables it -- an assistant repo
            # with no such config gets no bound socket at all, matching
            # §17 invariant 10 (localhost only) taken to its natural
            # extreme: no config means no listener, not a listener nobody
            # asked for. `_discover_metrics_configs`' first entry's
            # host/port is what gets bound (v1 multi-root choice, design
            # doc); every enabled root's metrics still render on that one
            # shared server via `_metrics_roots_provider` (live, re-scanned
            # per scrape) regardless of whose host/port was used to bind
            # it.
            enabled = self._discover_metrics_configs()
            self._metrics_server = None
            self._metrics_thread = None
            if enabled:
                _root, host, port = enabled[0]
                # 2026-08-02 live incident: the shared port is machine-wide,
                # so a stale neural-view from another worktree (or any other
                # squatter -- 9464 is also OTel's standard exporter port)
                # already holding it made this raise EADDRINUSE out of
                # start() and killed the WHOLE server at boot. Metrics are
                # an optional side-car: bind failure is one stderr line and
                # no exposition, never a boot blocker (same posture as
                # neural-view.py's whisper-sidecar autostart).
                try:
                    self._metrics_server, self._metrics_thread = observability.start_metrics_server(
                        host, port, self._metrics_roots_provider)
                except OSError as e:
                    print(f"assistant: metrics exposition disabled -- cannot bind {host}:{port} ({e})",
                          file=sys.stderr)

    def stop(self, timeout=5.0):
        """Signal every worker's stop_event and join each with a bounded
        timeout, so a server shutdown never hangs on a stuck worker.
        Idempotent: safe to call again (or on an engine that was never
        started) -- a second call just finds nothing left to stop."""
        with self._lock:
            workers, self.workers = self.workers, []
            metrics_server, self._metrics_server = self._metrics_server, None
            metrics_thread, self._metrics_thread = self._metrics_thread, None
        for _, _, stop_event in workers:
            stop_event.set()
        for _, thread, _ in workers:
            thread.join(timeout=timeout)
        # AST-042: bounded stop for the metrics server too -- shutdown()
        # unblocks its serve_forever() loop, the join bounds how long stop()
        # can wait on it (same posture as every WORKER_NAMES thread above),
        # and server_close() only runs once the thread has actually
        # exited, releasing the listening socket instead of racing an
        # in-flight request against it.
        if metrics_server is not None:
            metrics_server.shutdown()
            if metrics_thread is not None:
                metrics_thread.join(timeout=timeout)
            metrics_server.server_close()

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
        if method == "GET" and path == "/assistant/metrics":
            return 200, self._metrics(), "application/json"
        if method == "GET" and path == "/assistant/traces":
            return self._traces(query)
        if method == "GET" and path == "/assistant/tasks":
            return self._tasks(query)
        if method == "GET" and path.startswith("/assistant/artifact/"):
            # AST-068 (Sec12.2, issue #343): the ONE route whose id lives
            # in the URL PATH, not the query string -- see `_artifact`'s
            # own docstring for why that parsing stays here rather than
            # leaking into do_GET, and for this route's distinct success-
            # payload shape (an absolute file path, not JSON/text -- the
            # caller must stream it, never `_send()` it as a literal body).
            return self._artifact(path, query)
        if method == "POST" and path == "/assistant/chat":
            return self._chat(body)
        if method == "POST" and path == "/assistant/select":
            return self._select(body)
        if method == "POST" and path == "/assistant/skip":
            return self._skip()
        if method == "GET" and path == "/assistant/settings":
            return 200, {"askAgain": self._ask_again}, "application/json"
        if method == "POST" and path == "/assistant/settings":
            return self._settings(body)
        if method == "POST" and path == "/assistant/voice-event":
            return self._voice_event(body)
        return None

    def _persist_selection(self):
        """Writes the CURRENT `_selected`/`_gated`/`_ask_again`/
        `_last_active` quadruple to `selection_store` (§7.5, and AST-024's
        additive `lastActive`, §7.7/§7.8). Callers hold `_selection_lock`
        across both the in-memory mutation and this call, so a concurrent
        request never observes the fields mutated but not yet persisted
        (or persisted out of order against another concurrent write) --
        the same "mutate and persist under one lock" shape
        `_chat_lock_for`'s critical section uses for a whole turn, applied
        here to the smaller selection-state update."""
        selection_store.save(self.state_dir, self._selected, self._gated,
                              self._ask_again, self._last_active)

    def _status(self):
        """GET /assistant/status -- extended for AST-021 (SPEC-ASSISTANT.md
        §7.2-§7.4): carries the FULL scan result (`outcome`, `candidates`)
        so the page can branch on the exact same one/multiple/none
        classification `discovery.scan` computed, plus this engine
        instance's current selection state (`selected`, `gated`). `gated`
        is true when Skip was explicitly chosen (§7.3) OR when there is no
        assistant to select at all (`outcome == "none"`, §7.4) -- the page
        needs one boolean to decide whether to hard-gate voice/chat, it
        should not have to re-derive "none means gated" itself.

        #492: each candidate also carries its resolved `llm`
        (`_candidate_llm`) -- the chat overlay header resolves the selected
        assistant's model id LOCALLY off this same list (including on
        #485 tab switches) rather than a second round-trip."""
        scan = discovery.scan(root for _, root in self._repos_getter())
        candidates_payload = [
            {
                "name": _main_name(section),
                "aliases": default_store._names(section)[1:],
                "root": str(root),
                "llm": _candidate_llm(section),
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
            # AST-022 (§7.5): so the page's boot branch can decide "still
            # show the picker" vs. "apply the remembered selection" without
            # a second round-trip to /assistant/settings.
            "askAgain": self._ask_again,
        }

    def _select(self, body):
        """POST /assistant/select {"name": str} ->
        {"selected", "gated"[, "digest"]} (§7.2/§7.3, AST-021; switch flow
        + digest §7.7/§7.8, AST-024). `name` is resolved case-insensitively
        against the CURRENT scan's candidates' names/aliases via
        `default_store._matches_name` -- the exact same matching rule the
        §7.6 chat resolution path already uses, so a candidate's alias list
        is interpreted identically everywhere rather than by two matchers
        that could drift apart. An unmatched/ambiguous name is a 404-style
        error listing the real candidates, never a crash or a silent
        no-op. Selecting always clears an earlier Skip (`_gated` -> False)
        -- picking an assistant un-gates voice/chat for the rest of this
        engine's process lifetime AND, per AST-022 (§7.5), is persisted via
        `_persist_selection()` so a second tab, a page reload, or a
        restarted engine over the same `state_dir` agrees.

        AST-024 SWITCH FLOW (§7.7), on top of AST-021/022's plain select:
        a "switch" is a select whose resolved name DIFFERS from the
        PREVIOUSLY selected one, AND there was a previously selected one
        (an initial pick -- `self._selected` was None -- is not a switch,
        it has nothing to flush or digest). On a real switch:

          - "flush in-flight turn state": §7.6/§8's turn pipeline is
            synchronous per-HTTP-request (`_chat` runs load -> run_turn ->
            save entirely on the request thread, under `_chat_lock_for`,
            and returns before the next request is even accepted) -- there
            is no queued/in-progress turn living in engine memory across
            requests to abandon. This is a documented NO-OP today for that
            reason, not an oversight (see docs/spec-deltas/AST-024.md);
            what this method DOES actively do is reset the per-assistant
            selection state below, which is the only cross-request state
            engine.py holds for "which assistant is active".
          - worker threads (`self.workers`) are NEVER touched here --
            §7.7's "keep BOTH assistants' background work running
            throughout" holds trivially because the worker registry has no
            per-assistant identity yet (AST-010: workers are per-ENGINE,
            not per-assistant) and this method's body never reads or
            writes `self.workers`.
          - the OUTGOING assistant's `_last_active[old]` is stamped `now`
            -- "now" is the moment it stopped being active, which is
            exactly the anchor §7.8's digest for its NEXT activation needs
            ("activity since last active" == activity since this stamp).
          - the INCOMING assistant's digest is built from its OWN prior
            `_last_active` entry (before this stamp -- an assistant does
            not digest against itself) via `digest_module.digest`; see
            that module's docstring for what "since" means when no prior
            entry exists (None -- "since the beginning of recorded
            history", never fabricated, never an error).
          - `digest` is INCLUDED in the response ONLY on a real switch --
            an initial select (nothing to switch FROM) or a same-name
            reselect (no change at all) return the plain AST-021/022
            shape unchanged, so existing callers (the picker, a same-name
            switcher click) see no new key.
        """
        body = body if isinstance(body, dict) else {}
        name = body.get("name")
        if not isinstance(name, str) or not name.strip():
            return 400, {"error": "name is required"}, "application/json"

        scan = discovery.scan(root for _, root in self._repos_getter())
        matches = [
            (root, section) for root, section in scan.candidates
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

        matched_root, matched_section = matches[0]
        new_name = _main_name(matched_section)

        # issue #388: only the in-memory bookkeeping (old/new names,
        # is_switch, stamping _last_active, reading since_ts, persisting)
        # runs under `_selection_lock` -- `digest_module.digest()` below
        # does real disk I/O (brain-events.jsonl + the whole session
        # transcript) and must NOT run while the lock is held, or a
        # concurrent select/skip that only needs the lock stalls behind
        # this switch's digest read for no reason. `since_ts` is captured
        # here (inside the lock, off `self._last_active` as it stood at
        # this switch) so the digest call below is self-contained and
        # needs no further access to engine state.
        with self._selection_lock:
            old_name = self._selected
            is_switch = old_name is not None and old_name != new_name

            since_ts = None
            if is_switch:
                now = _now_iso()
                # the outgoing assistant stops being active now -- see
                # this method's docstring for why "now" is the correct
                # anchor for ITS next digest, not for this one.
                self._last_active[old_name] = now
                since_ts = self._last_active.get(new_name)

            self._selected = new_name
            self._gated = False
            self._persist_selection()

        payload = None
        if is_switch:
            payload = digest_module.digest(matched_root, since_ts)

        response = {"selected": self._selected, "gated": self._gated}
        if payload is not None:
            response["digest"] = payload
        return 200, response, "application/json"

    def _skip(self):
        """POST /assistant/skip -> {"selected": null, "gated": true}
        (§7.3). Hard-gates chat (via `_chat`'s gate check below) for the
        rest of this engine's process lifetime, or until a later
        /assistant/select -- §17.9's "no assistant selected" invariant,
        made explicit rather than merely implied by `selected` staying
        null. Persisted (AST-022, §7.5) the same way `_select` is, so a
        Skip survives a page reload / second tab / engine restart too."""
        with self._selection_lock:
            self._selected = None
            self._gated = True
            self._persist_selection()
        return 200, {"selected": None, "gated": True}, "application/json"

    def _settings(self, body):
        """POST /assistant/settings {"askAgain": bool} -> {"askAgain": bool}
        (§7.5): toggles the persisted "ask again on load" setting. `true`
        means every future boot forces a fresh pick (`__init__` resets
        `_selected`/`_gated` to the "nothing selected yet" state on such a
        boot even though a prior selection is still on disk); `false`
        means a future boot loads and applies the last persisted selection
        automatically. Does NOT itself change `_selected`/`_gated` for the
        CURRENT, already-running engine -- only what the NEXT boot does
        with what is on disk. A non-bool `askAgain` is a 400, not a silent
        coercion (matching `_select`'s "clean error, never a silent
        no-op" convention)."""
        body = body if isinstance(body, dict) else {}
        ask_again = body.get("askAgain")
        if not isinstance(ask_again, bool):
            return 400, {"error": "askAgain must be a boolean"}, "application/json"
        with self._selection_lock:
            self._ask_again = ask_again
            self._persist_selection()
        return 200, {"askAgain": self._ask_again}, "application/json"

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
        # The session's SELECTED assistant threads through as `?assistant=`
        # (the same flag `_chat`/`_traces`/`_tasks` already accept, #453/
        # #479's family) -- without it, a page refresh with an assistant
        # selected but no machine-level default resolves some OTHER
        # assistant's transcript (or none), which the human hit live as
        # "refresh resets the chat to a stale initial state" (2026-07-29):
        # the overlay rendered a different assistant's session history.
        assistant_flag = None
        if query:
            assistant_values = query.get("assistant")
            if assistant_values and assistant_values[0]:
                assistant_flag = assistant_values[0]
        candidates = default_store.discover_candidates(
            root for _, root in self._repos_getter()
        )
        try:
            root, _section = default_store.resolve_assistant(
                candidates, flag=assistant_flag, state_dir=self.state_dir)
        except default_store.ResolutionError as exc:
            # No assistant unambiguously resolved (none discovered, or
            # multiple with no stored default) -- an empty, explained
            # result rather than a 404/500; §5a routes never crash on an
            # absent selection, matching /assistant/status's `selected:
            # None` treatment of the same not-yet-selected state.
            return {"exchanges": [], "warnings": [f"no assistant resolved: {exc}"]}
        return SessionStore(root).history(n)

    def _metrics(self):
        """GET /assistant/metrics -- SPEC-ASSISTANT.md §10.5, issue #329:
        `{"roots": {label: observability.root_metrics(root), ...}}` for
        EVERY currently-discovered candidate (not just the resolved/
        selected one -- unlike `_history`/`_chat`, this is a fleet-wide
        view, matching `_status`'s own "every candidate" posture rather
        than a single resolved assistant). Roots are resolved the same way
        `_status` does (`discovery.scan` over the live `_repos_getter()`),
        so a marker added/removed after boot is reflected on the very next
        poll here too.

        A root with no `traces.sqlite` yet is NEVER an error --
        `observability.root_metrics` (built on `_compute_root_metrics`,
        which is itself built on `query()`, which returns `[]` for a
        missing db) naturally yields all-zero counters for such a root,
        so this method's only job is resolving WHICH roots to report on,
        never guarding against an absent db."""
        scan = discovery.scan(root for _, root in self._repos_getter())
        out = {}
        for root, section in scan.candidates:
            label = _main_name(section) or str(root)
            out[label] = observability.root_metrics(root)
        return {"roots": out}

    def _traces(self, query):
        """GET /assistant/traces?since=&turn=&limit=&assistant=&order= --
        SPEC-ASSISTANT.md §10.5, issue #329 (`assistant` added by AST-045,
        issue #331; `order`/`truncated` added by #393): `(status, payload,
        "application/json")` -- `payload` is `{"events": [...], "truncated":
        bool}` (or `{"events": [], "warnings": [...]}` when nothing
        resolves, no `truncated` key -- an unresolved assistant is a
        different "nothing to report" than a resolved-but-empty root) from
        `observability.query` against one resolved assistant -- one
        currently-selected/resolvable session, not a fleet-wide view like
        `_metrics` (traces are per-session correlation data; `_metrics` is
        the fleet dashboard's aggregate). A resolution failure mirrors
        `_history`'s own ResolutionError handling exactly (an empty,
        explained 200, never a 4xx/500) so both read-surface endpoints
        agree on what "nothing to report on yet" looks like.

        `since` is `observability.query`'s own `since` contract -- a `seq`
        RESUME CURSOR (`seq > since`), NOT a timestamp, despite this
        route's own `since=<iso>`-shaped naming in casual spec prose (§10.5)
        -- see `observability.query`'s docstring for why a seq cursor, not
        a timestamp, is the one that stays index-backed. `turn` filters to
        one `turn_id`. `limit` is parsed/clamped by the module-level
        `_parse_traces_query` (default `TRACES_DEFAULT_LIMIT`, hard cap
        `TRACES_MAX_LIMIT` -- same "bounded read" shape `_parse_history_n`
        already uses for `/assistant/history?n=`). `assistant` is an
        OPTIONAL §7.6 resolution flag -- passed straight through to
        `resolve_assistant(flag=...)`, the exact same parameter `_chat`'s
        body-level `assistant` key already feeds -- so the terminal's own
        `trace`/`events --assistant NAME` (AST-045) can target a NAMED
        root instead of whichever one resolves by default, mirroring
        `_chat`'s own flag -> sole assistant -> local default -> error
        order rather than inventing a second resolution rule.

        `order` (#393) is `"asc"` (default, back-compat) or `"desc"` --
        passed straight through to `observability.query`'s own `order`
        (see its docstring: `desc` selects the NEWEST `limit` rows, still
        returned seq-ascending). An `order` value that is neither is a
        clean 400 -- unlike `since`/`limit`'s "malformed degrades to the
        permissive default" posture, an unrecognized `order` is a caller
        mistake worth surfacing rather than silently guessing a direction.

        `truncated` is `True` exactly when `len(events) == limit` -- an
        honest "possibly more" signal (the off-by-one case where the true
        count is EXACTLY `limit` reads as truncated too; #393's fix is
        choosing never-a-false-negative over that rare false-positive,
        since the caller-side cost of an unnecessary caveat is far lower
        than the cost of a silently incomplete window).

        issue #391: `observability.query`'s own busy_timeout only covers
        ordinary write/read contention -- a VACUUM (AST-041's retention
        prune pass, Sec10.3) holds an exclusive lock long enough to run
        past it on a busy root, and `query` lets that surface as a raw
        `sqlite3.OperationalError` rather than swallowing it (it already
        swallows "no such table" the same way, see its own docstring).
        This route catches that specific, retryable condition and
        degrades to the SAME `{"events": [], "warnings": [...]}` shape the
        ResolutionError branch above already returns -- a lock overrun is
        transient (the caller's next poll will very likely succeed), never
        a 5xx/crash."""
        since, turn, limit, assistant_flag, order, order_error = _parse_traces_query(query)
        if order_error:
            return 400, {"error": order_error}, "application/json"
        candidates = default_store.discover_candidates(
            root for _, root in self._repos_getter()
        )
        try:
            root, _section = default_store.resolve_assistant(
                candidates, flag=assistant_flag, state_dir=self.state_dir)
        except default_store.ResolutionError as exc:
            # Same "empty, explained result, never a crash" posture as
            # `_history`'s own ResolutionError handling above.
            return 200, {"events": [], "warnings": [f"no assistant resolved: {exc}"]}, "application/json"
        try:
            events = observability.query(root, since=since, turn=turn, limit=limit, order=order)
        except sqlite3.OperationalError as exc:
            # issue #391: a VACUUM-style lock overrun -- clean, retryable,
            # never a crash (same posture as the ResolutionError branch
            # above, and as `query`'s own internal "no such table" degrade).
            return 200, {
                "events": [],
                "warnings": [f"traces temporarily unavailable, retry shortly: {exc}"],
            }, "application/json"
        truncated = limit > 0 and len(events) == limit
        return 200, {"events": events, "truncated": truncated}, "application/json"

    def _tasks(self, query):
        """GET /assistant/tasks?assistant=&state=&limit= -- SPEC-ASSISTANT.md
        §12.5's "queue indicator" data endpoint (AST-066, issue #341):
        `(200, {"tasks": [...]}, "application/json")` from
        `tasks.list_tasks` against ONE resolved assistant -- the same
        per-session resolution shape `_history`/`_traces` already use
        (a voice panel's queue indicator is about the CURRENTLY ACTIVE
        assistant, not a fleet-wide view like `_metrics`), never a
        4xx/500 on an unresolved assistant (mirrors `_history`'s/
        `_traces`'s own ResolutionError handling exactly: an empty,
        explained 200).

        `state` (optional) filters to one of `tasks.STATES`; an
        unrecognized value is a clean 400 (same "a present-and-invalid
        value is a caller mistake worth surfacing" posture `_traces`
        already applies to its own `order` param, not the "malformed ->
        silently degrade" posture `since`/`limit` get -- there is no
        sane state name meant to be a typo). `limit` defaults to
        `TASKS_DEFAULT_LIMIT`, clamped to `[0, TASKS_MAX_LIMIT]`, same
        `_parse_history_n`-style bounded-read shape as everywhere else.

        A task queue that hasn't been created yet (`tasks.sqlite` absent)
        is NEVER an error -- `list_tasks` already returns `[]` for that
        case, so this method's only job is resolving WHICH root and
        WHICH state filter to read, same posture `_metrics` documents for
        an absent `traces.sqlite`."""
        state, limit, assistant_flag, state_error = _parse_tasks_query(query)
        if state_error:
            return 400, {"error": state_error}, "application/json"
        candidates = default_store.discover_candidates(
            root for _, root in self._repos_getter()
        )
        try:
            root, _section = default_store.resolve_assistant(
                candidates, flag=assistant_flag, state_dir=self.state_dir)
        except default_store.ResolutionError as exc:
            return 200, {"tasks": [], "warnings": [f"no assistant resolved: {exc}"]}, "application/json"
        try:
            task_rows = tasks.list_tasks(root, state=state, limit=limit)
        except sqlite3.OperationalError as exc:
            # Same transient-lock-overrun degrade `_traces` applies for
            # `observability.query` -- clean and retryable, never a crash.
            return 200, {
                "tasks": [],
                "warnings": [f"tasks temporarily unavailable, retry shortly: {exc}"],
            }, "application/json"
        return 200, {"tasks": task_rows}, "application/json"

    def _artifact(self, path, query):
        """GET /assistant/artifact/<task-id>?assistant= -- SPEC-ASSISTANT.md
        Sec12.2 (AST-068, issue #343): resolves a task id to its
        completed artifact's safe absolute path on disk, scoped to the
        resolved assistant's OWN artifacts directory. This method never
        touches a socket or reads file content -- do_GET (neural-view.py)
        streams the actual bytes with real Range support; matches every
        other `_<name>` handler's "engine package stays HTTP-framework-
        agnostic" posture (see this module's own top-of-file convention).

        Path parsing: the task id lives in the URL PATH, not the query
        string -- unlike every other route here. Parsed in THIS method
        (not do_GET) so path-segment parsing for `/assistant/*` routes
        stays centralized in one place, same division of labor
        `_history`/`_traces`'s own docstrings describe for query-string
        parsing (`do_GET` reads the query string once; each route's OWN
        method interprets it). A task id containing `/` is rejected
        immediately -- real ids are `uuid.uuid4().hex` (tasks.py's
        `enqueue`), which never contain one; this also means a
        `../`-shaped path segment never reaches `artifacts.resolve` at
        all, let alone the filesystem.

        `assistant` is the SAME optional Sec7.6 resolution flag `_traces`/
        `_tasks` already accept, resolved via the identical
        `discover_candidates`/`resolve_assistant` pattern.

        Returns (status, payload, ctype):
          - success: `(200, <absolute file path str>, <ignored — do_GET
            recomputes the real media type from the resolved path>)` --
            the payload is NOT the response body; do_GET recognizes this
            route (see `handle()`'s own routing comment) and streams from
            that path instead of calling `_send()` on it.
          - every failure -- unresolved assistant, malformed task id, no
            such task, task not completed, no artifact recorded, a path
            that would escape the artifacts root, or a missing file --
            is the SAME generic `(404, {"error": "artifact not found"},
            "application/json")`. Deliberately undifferentiated (issue
            #343 review: "treat it as a traversal surface") -- a crafted
            id gets no more signal back than a legitimate but
            not-yet-completed one would.
          - a transient sqlite lock overrun (the same condition `_traces`/
            `_tasks` already degrade) is `(503, {"error": "..."},
            "application/json")` -- honestly retryable, unlike `_traces`/
            `_tasks`'s own degrade: those two have a sane "empty success"
            shape to fall back to (a list can legitimately be empty), an
            artifact request does not (there is nothing to return), so
            faking a 200 or a 404 here would be dishonest either way --
            a 503 is the one status that says "not this response's
            fault, ask again"."""
        task_id = path[len("/assistant/artifact/"):].strip("/")
        if not task_id or "/" in task_id:
            return 404, {"error": "artifact not found"}, "application/json"
        assistant_flag = None
        if query:
            values = query.get("assistant")
            if values:
                assistant_flag = values[0]
        candidates = default_store.discover_candidates(
            root for _, root in self._repos_getter()
        )
        try:
            root, _section = default_store.resolve_assistant(
                candidates, flag=assistant_flag, state_dir=self.state_dir)
        except default_store.ResolutionError:
            return 404, {"error": "artifact not found"}, "application/json"
        try:
            abs_path, _size = artifacts.resolve(root, task_id)
        except artifacts.ArtifactError:
            return 404, {"error": "artifact not found"}, "application/json"
        except sqlite3.OperationalError as exc:
            return 503, {"error": f"artifact temporarily unavailable, retry shortly: {exc}"}, "application/json"
        return 200, abs_path, "application/octet-stream"

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

    def _enqueue_distill(self, root, user_text, assistant_text, chips):
        """AST-030: posts one exchange-ref to the `distiller` worker's
        queue, O(1) and NEVER blocking the calling (HTTP request) thread --
        `queue.Queue.put_nowait` either succeeds immediately or raises
        `queue.Full` immediately, there is no wait either way. On overflow
        (queue.Full) this evicts the OLDEST queued item to make room for
        the newest one (see DISTILLER_QUEUE_MAXSIZE's docstring for why
        drop-oldest is the chosen policy) -- both the eviction and the
        retry are themselves non-blocking `_nowait` calls, so a full queue
        never turns into so much as a brief stall on this thread. A raced
        eviction (another producer's `get_nowait`/`put_nowait` slips in
        between this method's own two calls) degrades to silently dropping
        THIS item rather than blocking or raising -- acceptable per
        Sec9.5's "turns never block on the distiller" invariant; the
        exchange itself is already durably in session.jsonl regardless."""
        item = {
            "root": root,
            "identities": os.path.join(root, ".claude", "identities"),
            "exchange": {"user": user_text, "assistant": assistant_text, "chips": chips},
        }
        q = self.queues["distiller"]
        try:
            q.put_nowait(item)
        except queue.Full:
            try:
                q.get_nowait()
            except queue.Empty:
                pass
            try:
                q.put_nowait(item)
            except queue.Full:
                pass

    def _enqueue_artifact_note(self, root, turn_id, user_text, file_name):
        """Chat-artifact memory (2026-07-29): posts one artifact-note item
        to the distiller queue (the single sanctioned brain-write thread,
        §9.5/§17.5) -- distill.mint_artifact_note mints it. Non-blocking,
        drop-on-overflow, same posture as _enqueue_distill; a dropped item
        loses only the memory note, never the file itself."""
        item = {
            "root": root,
            "identities": os.path.join(root, ".claude", "identities"),
            "artifact_note": {
                "file": file_name,
                "turn_id": turn_id,
                "prompt": (user_text or "")[:300],
                "created": _now_iso(),
            },
        }
        q = self.queues["distiller"]
        try:
            q.put_nowait(item)
        except queue.Full:
            try:
                q.get_nowait()
            except queue.Empty:
                pass
            try:
                q.put_nowait(item)
            except queue.Full:
                pass

    def _enqueue_gap_note(self, root, gap_note):
        """AST-071 (SPEC-ASSISTANT.md Sec11.8, Sec9.5/Sec17.7): posts one
        capability-acquire-offer plan-note payload to the distiller
        worker's queue -- distill.mint_gap_note mints it (a parking-lot
        zettel, never an installation). Same non-blocking, drop-oldest-on-
        overflow posture as `_enqueue_artifact_note`/`_enqueue_distill`: a
        dropped item loses only the parked plan note, never the turn or
        its reply."""
        item = {
            "root": root,
            "identities": os.path.join(root, ".claude", "identities"),
            "gap_note": gap_note,
        }
        q = self.queues["distiller"]
        try:
            q.put_nowait(item)
        except queue.Full:
            try:
                q.get_nowait()
            except queue.Empty:
                pass
            try:
                q.put_nowait(item)
            except queue.Full:
                pass

    def _trace_directive(self, root, turn_id, directive, status):
        """#508: one `skill.request` trace event per parsed directive
        (Sec10.1) -- `status` is `"parsed"` for the directive
        `_capability_reply_hook_for` is about to act on, or `"ignored"`
        for any EXTRA directive found beyond the first (v1: at most one
        capability invocation per turn, no chains; docs/spec-deltas/
        508.md). A `turns.CapabilityDirectiveError` (malformed JSON, or a
        block missing a usable `name`) traces its `reason` instead of a
        name/params pair -- still one event, never silently dropped."""
        if isinstance(directive, turns.CapabilityDirectiveError):
            payload = {"reason": directive.reason}
        else:
            payload = {"name": directive.name, "params": directive.params}
        self._emit_trace(root, "skill.request", turn_id=turn_id, status=status, payload=payload)

    def _capability_reply_hook_for(self, root, turn_id, user_message, assistant_cfg):
        """#508 (SPEC-ASSISTANT.md Sec9.4/Sec9.5, Sec11.5, Sec11.8,
        docs/design/ast-E6.md sequences 2/3/5): builds the `on_reply` hook
        `turns.run_turn` calls (see that function's docstring for the
        exact contract) -- the request -> resolve -> invoke -> (gap) loop
        this task exists to wire up. Returns a closure so `_chat` can bind
        `root`/`turn_id`/`user_message`/`assistant_cfg` (the resolved
        `section` dict) once per turn without a longer positional
        signature on the hook itself.

        `_hook(first_text, context_for_adapter, complete_fn,
        adapter_kwargs)`:
          1. Parses EVERY directive out of `first_text` (`turns.
             parse_capability_directives`). NO directive at all -> returns
             `None` immediately, touching NOTHING else (capability_index,
             adapters, the tasks queue, or any trace event) -- the
             flooding-guard discipline #346 already established for
             `_capability_gap_check`, extended here to the WHOLE loop:
             ordinary chat stays exactly as cheap as before this task.
          2. Traces every directive as `skill.request` (the ACTED-ON one
             -- `directives[0]`, and only when it is also `actionable` --
             as `"parsed"`; every OTHER directive found, including a
             VALID `directives[0]` that failed the trailing-position
             check, as `"ignored"` -- v1 never chains, and round-1 review
             finding 3 ("teach-then-quote": a model demonstrating the
             syntax mid-explanation, confirmed live by review, must never
             fire) means being FIRST is necessary but not sufficient; see
             `turns.parse_capability_directives`'s own docstring for the
             exact `actionable` rule).
          3. A malformed FIRST directive (`CapabilityDirectiveError`) never
             reaches capability_index at all -- traced as `skill.error`
             (reason `"invalid_directive"`) and replied to honestly,
             UNCONDITIONALLY (regardless of trailing position -- a
             malformed block's intent can never be inferred from where it
             sits, so it is always surfaced the same way).
          4. Resolves `directives[0]`'s name against the already-compiled
             index (`capability_index.resolve_by_name` -- case-
             insensitive, independent of any relevance score, Sec11.2's
             "two invisibility tiers" mean a disabled capability is
             indistinguishable here from a never-installed one). No
             match -> `_capability_gap_check(..., requested_name=...)`
             (the SAME #346 gap machinery, now given the real trigger it
             was missing) and its refusal text becomes the turn's reply.
          5. A match with `provisioned_ok` false -> a refusal naming the
             capability and its `unavailable_reason` (Sec11.4: never
             present an unavailable ability as usable) -- traced as
             `skill.error` (reason `"unprovisioned"`), never a gap
             (something WAS found, just not usable right now).
          6. A match whose `capability.yaml` declares `longRunning: true`
             -> `tasks.enqueue`s a `capability_index.KIND` task instead of
             invoking inline (Sec9.4 sequence 3) under
             `CAPABILITY_TASK_TIMEOUT_SECONDS` (round-1 review, HIGH
             finding 1 -- a DISTINCT, more generous bound than the inline
             path's; reusing the inline bound silently killed a queued
             task the user had already been told was safely backgrounded)
             and replies that the work is queued -- no inline spawn.
          7. Otherwise: `capability_index.invoke_capability` under
             `CAPABILITY_INVOKE_TIMEOUT_SECONDS`, bracketed by
             `skill.invoke` start/ok trace events sharing one span_id
             (parent_span_id=turn_id, i.e. turn-linked); `adapters.
             ParamValidationError` (invalid/missing params -- rejected
             BEFORE any spawn, by `invoke_argv`/`invoke_mcp`'s own
             pre-substitution validation) and `adapters.Timeout` each get
             their own `skill.error` status/reason and a graceful reply;
             any other `adapters.AdapterError` is caught the same way. On
             success, the result (`turns.render_capability_result_text`,
             size-capped with an explicit truncation marker) drives ONE
             same-turn follow-up `complete_fn` call
             (`turns.render_capability_result_followup` reuses the
             ALREADY-composed system prompt -- no second recall/compose)
             whose reply becomes the turn's final text. That follow-up
             call is itself wrapped in `adapters.AdapterError` handling
             (round-1 review finding 4): the capability has, at this
             point, ALREADY run -- letting a follow-up failure propagate
             up to `_chat`'s outer handler would 502 with NO exchange
             ever appended, discarding the executed action AND inviting a
             retry that would run it AGAIN, so a failed follow-up
             degrades to `turns.render_capability_completed_fallback`
             instead (a plain, result-bearing reply), traced as
             `skill.error` (reason `"followup_failed"`). The follow-up's
             OWN reply is re-scanned for a directive -- v1 NEVER honors
             one from a follow-up (one invocation per turn, full stop),
             so every directive found there is traced `"ignored"`
             regardless of its own `actionable` status. A follow-up reply
             that strips down to nothing (round-1 review finding 5 -- the
             model's follow-up was itself just another directive block,
             with no surrounding prose) falls back to the SAME
             result-bearing template rather than an empty 200.

        The ENTIRE hook body (from the first directive check onward) runs
        under one broad `try/except Exception` (round-1 review finding 8):
        the SAME "never raise into the caller, degrade to a traced error +
        plain reply" discipline `_capability_gap_check` already
        established -- an unexpected internal bug anywhere in this loop
        must never turn into a dropped connection with no `turn.end`
        event, it must degrade exactly like every OTHER failure mode
        above does."""
        def _hook(first_text, context_for_adapter, complete_fn, adapter_kwargs):
            visible_text, directives, actionable = turns.parse_capability_directives(first_text)
            if not directives:
                return None  # ordinary reply -- zero capability machinery touched

            try:
                primary = directives[0]
                for ignored in directives[1:]:
                    self._trace_directive(root, turn_id, ignored, status="ignored")

                if isinstance(primary, turns.CapabilityDirectiveError):
                    self._emit_trace(root, "skill.error", turn_id=turn_id, status="error", payload={
                        "reason": "invalid_directive", "detail": primary.reason,
                    })
                    return {"text": visible_text or "I could not understand that capability request."}

                if actionable is None:
                    # a VALID directive was found but is not the reply's
                    # trailing element (round-1 review finding 3:
                    # teach-then-quote) -- traced for observability, never
                    # invoked; the visible reply (fence already stripped)
                    # stands on its own. round-2 review (optional nit): NO
                    # "could not understand" fallback here -- unlike the
                    # malformed-directive branch above, `visible_text` can
                    # never be empty in this branch by construction: a
                    # valid `primary` only fails the trailing check when
                    # genuine, non-whitespace prose follows its fence (see
                    # parse_capability_directives's own `actionable` rule),
                    # and that same prose is what `visible_text` carries.
                    self._trace_directive(root, turn_id, primary, status="ignored")
                    return {"text": visible_text}

                self._trace_directive(root, turn_id, primary, status="parsed")

                index = self.capability_index_for(root)
                entry = capability_index.resolve_by_name(index, primary.name)
                if entry is None:
                    gap = self._capability_gap_check(root, turn_id, user_message, requested_name=primary.name)
                    return {"text": gap.text if gap is not None else visible_text}

                if not entry.provisioned_ok:
                    reason = entry.unavailable_reason or "not currently available"
                    self._emit_trace(root, "skill.error", turn_id=turn_id, status="refused", payload={
                        "reason": "unprovisioned", "capability": entry.name, "detail": reason,
                    })
                    return {"text": "%s is enabled but not available right now: %s" % (entry.name, reason)}

                skill_dir = os.path.join(str(root), ".claude", "skills", entry.name)
                capability = capability_index.load_capability(skill_dir)
                if isinstance(capability, capability_index.CapabilityError):
                    self._emit_trace(root, "skill.error", turn_id=turn_id, status="error", payload={
                        "reason": "reload_failed", "capability": entry.name, "detail": capability.reason,
                    })
                    return {"text": "%s could not be loaded right now." % entry.name}

                if capability.long_running:
                    task_payload = {
                        "name": entry.name,
                        "capability": capability._asdict(),
                        "params": primary.params,
                        "skill_dir": skill_dir,
                        "assistant_cfg": assistant_cfg if isinstance(assistant_cfg, dict) else {},
                        "timeout": CAPABILITY_TASK_TIMEOUT_SECONDS,
                    }
                    task_id = tasks.enqueue(self.queues["tasks"], root, capability_index.KIND,
                                             payload=task_payload, turn_id=turn_id)
                    if task_id is None:
                        self._emit_trace(root, "skill.error", turn_id=turn_id, status="error", payload={
                            "reason": "queue_full", "capability": entry.name,
                        })
                        return {"text": ("I could not queue %s right now (the task queue is full) -- "
                                           "please try again shortly." % entry.name)}
                    return {"text": ("I have queued %s to run in the background -- watch the "
                                       "artifact panel for the result." % entry.name)}

                span_id = uuid.uuid4().hex
                self._emit_trace(root, "skill.invoke", turn_id=turn_id, span_id=span_id,
                                  parent_span_id=turn_id, status="start",
                                  payload={"capability": entry.name})
                try:
                    result = capability_index.invoke_capability(
                        entry.name, capability, primary.params, assistant_cfg,
                        skill_dir=skill_dir, timeout=CAPABILITY_INVOKE_TIMEOUT_SECONDS)
                except capability_index.CapabilityDisabledError as exc:
                    self._emit_trace(root, "skill.error", turn_id=turn_id, span_id=span_id,
                                      parent_span_id=turn_id, status="refused", payload={
                                          "reason": "disabled", "capability": entry.name, "detail": str(exc),
                                      })
                    return {"text": "%s is disabled." % entry.name}
                except adapters.Timeout as exc:
                    self._emit_trace(root, "skill.error", turn_id=turn_id, span_id=span_id,
                                      parent_span_id=turn_id, status="timeout", payload={
                                          "capability": entry.name, "error": str(exc),
                                      })
                    return {"text": "%s took too long to respond, so I stopped waiting." % entry.name}
                except adapters.ParamValidationError as exc:
                    self._emit_trace(root, "skill.error", turn_id=turn_id, span_id=span_id,
                                      parent_span_id=turn_id, status="refused", payload={
                                          "reason": "invalid_params", "capability": entry.name, "detail": str(exc),
                                      })
                    return {"text": "I could not call %s: %s" % (entry.name, exc)}
                except adapters.AdapterError as exc:
                    self._emit_trace(root, "skill.error", turn_id=turn_id, span_id=span_id,
                                      parent_span_id=turn_id, status="error", payload={
                                          "capability": entry.name, "error": str(exc),
                                          "error_type": type(exc).__name__,
                                      })
                    return {"text": "%s failed: %s" % (entry.name, exc)}

                result_text, truncated = turns.render_capability_result_text(result)
                self._emit_trace(root, "skill.invoke", turn_id=turn_id, span_id=span_id,
                                  parent_span_id=turn_id, status="ok", payload={
                                      "capability": entry.name,
                                      "argv": list(getattr(result, "argv", None) or []),
                                      "truncated": truncated,
                                  })
                fallback_text = turns.render_capability_completed_fallback(entry.name, result_text)

                followup_context = turns.render_capability_result_followup(
                    context_for_adapter, entry.name, result_text)
                try:
                    followup = complete_fn(followup_context, **(adapter_kwargs or {}))
                except adapters.AdapterError as exc:
                    # round-1 review finding 4: the capability ALREADY ran
                    # -- losing that outcome (and inviting a retry that
                    # would re-run it) is worse than a rougher, templated
                    # reply. Degrade here, never let this propagate up to
                    # _chat's outer AdapterError handler, which 502s with
                    # NO exchange ever appended.
                    self._emit_trace(root, "skill.error", turn_id=turn_id, span_id=span_id,
                                      parent_span_id=turn_id, status="error", payload={
                                          "reason": "followup_failed", "capability": entry.name,
                                          "error": str(exc), "error_type": type(exc).__name__,
                                      })
                    return {"text": fallback_text}

                followup_visible, followup_directives, _followup_actionable = (
                    turns.parse_capability_directives(followup.get("text", "")))
                for found in followup_directives:
                    # v1: NOTHING from a follow-up reply is ever honored,
                    # one invocation per turn, full stop -- every directive
                    # found here is traced ignored regardless of its own
                    # actionable/trailing-position status.
                    self._trace_directive(root, turn_id, found, status="ignored")
                return {
                    # round-1 review finding 5: a follow-up that stripped
                    # down to nothing but a (never-honored) directive block
                    # falls back to the same result-bearing template as a
                    # failed follow-up call, never a blank reply.
                    "text": followup_visible or fallback_text,
                    "usage": followup.get("usage"),
                    "timings": followup.get("timings"),
                }
            except Exception as exc:
                # round-1 review finding 8: the SAME "never raise into the
                # caller" discipline _capability_gap_check already
                # established, extended to the whole hook -- an unexpected
                # internal bug here must degrade to a traced error + plain
                # reply, never a dropped connection with no turn.end.
                self._emit_trace(root, "skill.error", turn_id=turn_id, status="error", payload={
                    "reason": "internal_exception", "error": str(exc), "error_type": type(exc).__name__,
                })
                return {"text": "Something went wrong while handling that request."}
        return _hook

    def _capability_gap_check(self, root, turn_id, message, requested_name=None):
        """AST-071 (SPEC-ASSISTANT.md Sec11.8, docs/design/ast-E6.md
        sequence 5): runs `turns.capability_gap_reply` off the SAME
        already-compiled index `_roster_provider_for` reads (Sec11.3: no
        index recompute) and, on a genuine gap, emits a first-class
        `skill.gap` trace event (turn-linked, Sec10.1 -- `skill.*` is one
        of §10.1's enumerated event-kind namespaces; review round 1 fix #4
        renamed this from `capability.gap`, which was not) and enqueues
        the MAY-offer acquire-plan draft onto the distiller queue --
        turn_id/created are stamped onto the payload here since turns.py
        itself never touches a queue or a clock (Sec9.5/Sec17.7). Never
        alters any reply text -- it only has trace/background-note side
        effects. Never RAISES into the caller (a bug in gap detection must
        never break an otherwise-successful turn, Sec17) -- but per §10.6
        ("every error... SHALL be a first-class event linked from its
        turn") an internal failure is not silently swallowed either: it is
        reported as a `skill.gap.error` trace event carrying the turn_id
        and the error (review round 1 fix #5). Returns the `CapabilityGap`
        namedtuple on a genuine gap, `None` otherwise (#508: `_chat`'s
        directive-driven caller uses `gap.text` as the turn's actual reply;
        every #346-era caller that ignores the return value is unaffected).

        NOT auto-wired into EVERY `_chat` call with no signal at all
        (flagged design decision, docs/spec-deltas/346.md -- read this if
        extending the wiring further). `capability_index.roster_for_turn`
        returns `[]` (the pre-#508 gap trigger, still used when
        `requested_name` is omitted) both for a genuinely empty index (no
        capabilities installed at all -- the common v1 default) AND for
        any ordinary conversational turn that simply does not mention an
        installed capability; `_roster_provider_for`'s own docstring
        already establishes that AST-061 treats BOTH as "ordinary chat,
        completely unaffected" for roster injection. Calling this
        unconditionally on every turn (with NO `requested_name`) was tried
        and reverted: an 8-turn conversation against a skill-less
        assistant fixture minted 8 near-duplicate acquire-offer plan notes
        (one per turn) instead of the expected single distilled summary
        note -- a real, demonstrated flooding regression (it broke
        section-assistant-distill.sh's "N turns... trigger a real
        distilled mint" integration test).

        `requested_name` (#508, optional, `None` by default -- every
        pre-#508 caller/behavior is unaffected): threaded straight through
        to `turns.capability_gap_reply`'s own `requested_name` param -- see
        that function's docstring for the embedding-mode-independent,
        explicit-request gap trigger this enables. `_chat`'s directive-
        driven hook (`_capability_reply_hook_for` below) is the FIRST
        caller that supplies it, precisely the "actual capability-
        invocation attempt path" this method's docstring previously named
        as the missing trigger #508 needed to build."""
        try:
            index = self.capability_index_for(root)
            gap = turns.capability_gap_reply(index, message, requested_name=requested_name)
        except Exception as exc:
            self._emit_trace(root, "skill.gap.error", turn_id=turn_id, status="error", payload={
                "error": str(exc), "error_type": type(exc).__name__,
            })
            return None
        if gap is None:
            return None
        # review round 2 (NEW-2): `plan_note_drafted` was dropped from this
        # payload -- `turns.capability_gap_reply` now drafts a plan note
        # unconditionally on every gap (see `_draft_capability_acquire_offer`'s
        # docstring), so the field was always True and carried no signal.
        self._emit_trace(root, "skill.gap", turn_id=turn_id, status="gap", payload={
            "nearest": [entry.name for entry in gap.nearest],
            "requested_name": requested_name,
        })
        plan_note = dict(gap.plan_note)
        plan_note["turn_id"] = turn_id
        plan_note["created"] = _now_iso()
        self._enqueue_gap_note(root, plan_note)
        return gap

    def _emit_trace(self, root, kind, turn_id=None, span_id=None,
                     parent_span_id=None, status=None, payload=None,
                     modality="text"):
        """AST-040 (SPEC-ASSISTANT.md §10.1): a thin, enqueue-only wrapper
        over `observability.emit` bound to THIS engine's traces queue --
        every `_chat` call site below goes through this one spot rather
        than repeating `self.queues["traces"]` + the event-dict shape at
        each site. `session_id` is `os.path.realpath(root)` (the same
        canonicalization `_chat_lock_for` already uses to key a root) --
        one session per assistant per §7.5, so the root IS the session
        identity; there is no separate session table/id to look up.
        `modality` defaults to "text" (every turn-shaped event); AST-051's
        `_voice_event` passes "voice" for tts/stt spans -- same envelope,
        same writer, just a different tag on the same events table
        (§10.1's `modality` column exists for exactly this)."""
        observability.emit(self.queues["traces"], root, {
            "kind": kind,
            "session_id": os.path.realpath(root),
            "turn_id": turn_id,
            "span_id": span_id,
            "parent_span_id": parent_span_id,
            "modality": modality,
            "status": status,
            "payload": payload or {},
        })

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
        # #462 (P2, durable hardening of #453's client-side fix): #453
        # made dispatchNextChat thread window.__assistantSelected as
        # THIS route's `assistant` flag so a session with an assistant
        # selected but no machine-level default (setup-assistant.sh
        # set-default) and 2+ candidates does not hit "no local default
        # set and multiple assistants found" -- but that fix lived in
        # ONE client caller. Any future client that POSTs here without
        # threading the flag hits the exact same error again. Computed
        # HERE instead, strictly after the explicit flag (a caller-
        # provided flag, e.g. the terminal's own --assistant, always
        # wins unchanged) and never applied when there is a sole
        # candidate (that shortcut must keep working even if
        # self._selected is stale -- e.g. a repo config change removed
        # the previously-selected assistant since). See
        # _effective_chat_flag's own docstring for the exact contract.
        assistant_flag = _effective_chat_flag(
            assistant_flag, self._selected, len(candidates))
        try:
            root, section = default_store.resolve_assistant(
                candidates, flag=assistant_flag, state_dir=self.state_dir)
        except default_store.ResolutionError as exc:
            return 400, {"error": str(exc)}, "application/json"

        # AST-040 (SPEC-ASSISTANT.md §10.1/§10.6): one turn_id links every
        # trace event this turn emits (turn.start -> recall.summary/
        # provider.call|error -> turn.end); a fresh span_id per provider
        # attempt distinguishes the call itself from the turn as a whole.
        # Every emit below is enqueue-only (§17.7: never blocks this
        # request thread) and generated OUTSIDE the per-root chat lock so
        # a slow/backed-up traces queue can never contend with it.
        turn_id = uuid.uuid4().hex
        self._emit_trace(root, "turn.start", turn_id=turn_id, status="start",
                          payload={"message_len": len(message)})

        store = SessionStore(root)
        with self._chat_lock_for(root):
            session_state = store.load_state()
            provider_span_id = uuid.uuid4().hex
            try:
                # AST-061 (Sec11.3): a real, per-turn relevance-filtered
                # roster instead of the AST-013 `None` placeholder (which
                # `compose_context` treats as `default_roster_provider`,
                # always []) -- see `_roster_provider_for`'s docstring for
                # the ask-instead-of-guess rendering this closure applies.
                roster_provider = self._roster_provider_for(root, message)
                # File output (2026-07-29, human-directed; codex parity
                # 2026-08-01, issue #518): resolve the sanctioned
                # per-assistant output directory (the brain's media/chat/,
                # the SAME relative base the chat renderer's /file/ links
                # resolve) and inject it per-turn as `_fileOutputDir` --
                # turns.compose_context states it in the system prompt and
                # BOTH provider adapters relay it: claude.py scope-opens its
                # Write tool to an isolated cwd and publishes from there;
                # codex.py runs `-s workspace-write` confined to its `-C`
                # workdir and publishes from there (issue #518 -- codex
                # never wired the second half of this until then). `fileOutput:
                # false` in the assistant section disables it; a dir that
                # cannot be created degrades silently to the no-file-output
                # turn shape (the adapter still runs, just with no
                # fileOutputDir in context to publish into).
                persona_cfg = dict(section) if isinstance(section, dict) else section
                # Temporal grounding (2026-07-29, human-directed): the
                # assistant always knows the current wall clock, so
                # time-relative asks ("what did we do yesterday") work.
                # Injected per-turn (not in compose_context itself) so
                # hermetic compose tests stay deterministic.
                if isinstance(persona_cfg, dict):
                    persona_cfg["_nowText"] = (
                        datetime.now().astimezone().strftime("%A, %Y-%m-%d %H:%M %Z"))
                prev_out_files = set()
                if isinstance(persona_cfg, dict) and persona_cfg.get("fileOutput") is not False:
                    out_dir = os.path.join(
                        str(root), ".claude", "identities", "assistant",
                        "brain", "media", "chat")
                    try:
                        os.makedirs(out_dir, exist_ok=True)
                        persona_cfg["_fileOutputDir"] = out_dir
                        prev_out_files = set(os.listdir(out_dir))
                    except OSError:
                        persona_cfg.pop("_fileOutputDir", None)
                # #508 (SPEC-ASSISTANT.md Sec9.4/Sec9.5, Sec11.5, Sec11.8):
                # the request -> resolve -> invoke -> (gap) loop's engine-
                # side entry point -- see `_capability_reply_hook_for`'s
                # docstring for the full contract; `section` (the resolved
                # assistant config, captured before `persona_cfg` gets its
                # per-turn `_nowText`/`_fileOutputDir` keys mixed in) is
                # what `invoke_capability` needs as `assistant_cfg`.
                capability_reply_hook = self._capability_reply_hook_for(
                    root, turn_id, message, section)
                result = turns.run_turn(persona_cfg, roster_provider, None, session_state, message,
                                         on_reply=capability_reply_hook)
            except adapters.AdapterError as exc:
                # provider CLI failure (Sec8.5) -- a clean upstream error,
                # never a raw traceback, and never a persisted exchange
                # (nothing to append: the turn produced no reply). §10.6:
                # the error is a first-class event linked to this turn via
                # turn_id -- recorded even though the turn itself fails.
                self._emit_trace(root, "provider.error", turn_id=turn_id,
                                  span_id=provider_span_id, parent_span_id=turn_id,
                                  status="error",
                                  payload={"error": str(exc), "error_type": type(exc).__name__})
                self._emit_trace(root, "turn.end", turn_id=turn_id, status="error")
                return 502, {"error": str(exc)}, "application/json"

            store.append_exchange(message, result["text"])
            # Chat-artifact memory (2026-07-29, human-directed): any file
            # the turn just produced in the sanctioned output dir is
            # minted as a #chat-artifact note (when/what/which turn) --
            # enqueue-only onto the distiller worker (the one sanctioned
            # brain-write thread), same non-blocking posture as
            # _enqueue_distill.
            if isinstance(persona_cfg, dict) and persona_cfg.get("_fileOutputDir"):
                try:
                    now_files = set(os.listdir(persona_cfg["_fileOutputDir"]))
                except OSError:
                    now_files = set(prev_out_files)
                for new_name in sorted(now_files - prev_out_files):
                    if new_name.startswith("."):
                        continue
                    self._enqueue_artifact_note(root, turn_id, message, new_name)
            store.save_state(result["updated_session_state"])

        # Recall summary + provider.call are emitted together (both only
        # become available once run_turn returns successfully -- compose_
        # context computes chips before the adapter call internally, but
        # run_turn's own contract returns nothing on failure, so a failed
        # attempt above emits provider.error with no matching recall event;
        # see run_turn's docstring for that composed-then-called shape).
        chips = result["chips"]
        self._emit_trace(root, "recall.summary", turn_id=turn_id,
                          payload={"chip_count": len(chips),
                                   "slugs": [c.get("slug") for c in chips if isinstance(c, dict)]})
        self._emit_trace(root, "provider.call", turn_id=turn_id,
                          span_id=provider_span_id, parent_span_id=turn_id, status="ok",
                          payload={"usage": result.get("usage")})

        # AST-030 (Sec9.2/Sec9.5): enqueue-only, AFTER the turn's own
        # critical section has released the per-root lock -- a non-blocking
        # put to the distiller's worker slot, never a synchronous distill
        # on this request thread.
        self._enqueue_distill(root, message, result["text"], result["chips"])

        warnings = []
        if result.get("budget_report", {}).get("over_budget"):
            warnings.append("turn context exceeded the token budget")

        self._emit_trace(root, "turn.end", turn_id=turn_id, status="ok",
                          payload={"warnings": warnings})

        return 200, {
            "text": result["text"],
            "chips": result["chips"],
            "warnings": warnings,
        }, "application/json"

    def _voice_event(self, body):
        """POST /assistant/voice-event -- {"kind": "stt-start"|"stt-end"|
        "tts-start"|"tts-end", "assistant"?: str, "engine"?: str,
        "status"?: str, "payload"?: dict} -> {"ok": true}
        (SPEC-ASSISTANT.md §13.3, AST-051, issue #333).

        The voice panel (TTS AND STT alike) times its own spans entirely
        client-side -- the page is the only thing that knows an utterance's
        or a recognition session's real start/end. This route is a thin,
        enqueue-only bridge into the SAME `_emit_trace` -> traces.sqlite
        path every other span already uses (§10.1/§10.2's single-writer
        rule holds: no new writer, no new table, just a new way IN for the
        page to hand a span to the one writer that already exists).

        §17.9 (checked FIRST, exactly like `_chat` above): a gated session
        (assistant selection was skipped, or none exists) refuses every
        voice-event post with the same 403 shape `_chat` uses -- a stray
        client-side start (e.g. a race against the gate) never gets a
        span recorded, matching "voice is hard-gated off with no assistant
        selected" taken to its logical end: nothing to correlate the span
        to, and nothing should have started in the first place.

        `kind` is validated against `_VOICE_EVENT_KINDS` -- an unrecognized
        kind is a clean 400, never a silently-dropped or best-effort
        write. `engine` (when given) rides into the emitted event's
        `payload` dict alongside whatever the caller already supplied,
        keyed `engine` -- e.g. AST-051's stt-start/stt-end carry the chosen
        STT engine name ("whisper" | "web-speech") there, which is how a
        trace query can tell WHICH engine a given span belongs to.

        `assistant` resolution (#479) runs the SAME §7.6-style order `_chat`
        uses, `_effective_chat_flag` folded in identically: an explicit
        `assistant` flag always wins; otherwise, for 2+ candidates, the
        session's own selected assistant (self._selected, set via
        /assistant/select) is tried before falling through to the
        machine-local default; a sole candidate is never disturbed. Without
        this, a session with an assistant selected but no machine-level
        default 400'd on every voice-event post -- the client already
        threads window.__assistantSelected (emitVoiceSpan, mirroring
        dispatchNextChat's #453 fix), but that alone does not help any
        OTHER future caller of this route, exactly the gap #462 closed for
        `_chat`.
        """
        body = body if isinstance(body, dict) else {}
        if self._gated:
            return 403, {
                "error": "voice is gated off for this session (assistant "
                          "selection was skipped) -- see /assistant/select",
            }, "application/json"
        kind = body.get("kind")
        if kind not in _VOICE_EVENT_KINDS:
            return 400, {
                "error": "kind must be one of: " + ", ".join(sorted(_VOICE_EVENT_KINDS)),
            }, "application/json"

        assistant_flag = body.get("assistant")
        candidates = default_store.discover_candidates(
            root for _, root in self._repos_getter()
        )
        # #479: the SAME durable session-selected fallback #462 gave `_chat`
        # -- emitVoiceSpan (neural-view.html) threads window.__assistant
        # Selected the same way dispatchNextChat threads chatBody.assistant
        # (#453), but that client-side fix alone left THIS route exposed:
        # a session with an assistant selected but no machine-level default
        # and 2+ candidates 400'd with "no local default set and multiple
        # assistants found" on every voice-event POST, silently dropping
        # every span (fire-and-forget fetch, nothing surfaces client-side).
        # Reuses _effective_chat_flag verbatim -- see its own docstring for
        # the exact contract (explicit flag always wins; never applied for
        # a sole candidate; otherwise falls back to self._selected).
        assistant_flag = _effective_chat_flag(
            assistant_flag, self._selected, len(candidates))
        try:
            root, _section = default_store.resolve_assistant(
                candidates, flag=assistant_flag, state_dir=self.state_dir)
        except default_store.ResolutionError as exc:
            return 400, {"error": str(exc)}, "application/json"

        payload = body.get("payload") if isinstance(body.get("payload"), dict) else {}
        engine_name = body.get("engine")
        if engine_name:
            payload = dict(payload, engine=engine_name)

        self._emit_trace(root, kind, status=body.get("status"),
                          payload=payload, modality="voice")
        return 200, {"ok": True}, "application/json"

def _effective_chat_flag(explicit_flag, selected, candidate_count):
    """#462 (P2): the exact `assistant` flag `_chat` should pass into
    default_store.resolve_assistant(), with the session's OWN selected
    assistant (engine.AssistantEngine._selected, AST-022 sec7.5 -- set
    by /assistant/select, DISTINCT from default_store's machine-local
    default) folded in as a durable fallback for callers that do not
    thread it themselves (#453 threaded it from ONE client,
    dispatchNextChat; this is that same fallback made structural).

    Contract, in order:
    - `explicit_flag` (a caller-provided `assistant` field in the
      request body -- the terminal's own --assistant flag included)
      ALWAYS wins unchanged. This function is a no-op whenever it is
      truthy, so nothing downstream of the explicit-flag branch in
      resolve_assistant() (ambiguous-match errors, its exact wording,
      gates.py's own expectations of that path) is touched at all.
    - A sole candidate (`candidate_count == 1`) returns None
      unconditionally -- resolve_assistant()'s own "len(candidates) ==
      1" shortcut must keep resolving on its own, even if `selected`
      happens to be stale (e.g. a repo config change removed the
      candidate it used to name) or simply unset. Folding `selected` in
      here would turn an always-correct single-candidate resolution
      into a spurious ambiguous-match error for no reason.
    - Otherwise (no explicit flag, 2+ candidates): `selected` is
      returned as-is (which may be None -- resolve_assistant() falls
      through to the machine-local default exactly as before in that
      case, unchanged from pre-#462 behavior)."""
    if explicit_flag:
        return explicit_flag
    if candidate_count == 1:
        return None
    return selected


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


def _parse_traces_query(query):
    """Parses `GET /assistant/traces`'s `since`/`turn`/`limit`/`assistant`/
    `order` query params into `(since, turn, limit, assistant_flag, order,
    order_error)`. `since` parses as an int (a `seq` cursor -- see
    `AssistantEngine._traces`'s docstring for why, despite the route's own
    `since=<iso>`-shaped naming in casual spec prose); an absent/malformed
    value is `None` (no lower bound), same "malformed input degrades to
    the permissive default, never a 400" shape `_parse_history_n` already
    uses for `?n=`. `turn` is passed through verbatim (a `turn_id` string,
    no parsing needed). `limit` defaults to `TRACES_DEFAULT_LIMIT` and is
    clamped to `[0, TRACES_MAX_LIMIT]` -- never negative, never past the
    documented hard cap, regardless of what a client asks for. `assistant`
    (AST-045, issue #331) is passed through verbatim too -- an absent
    value is `None`, meaning "resolve however `_chat` would with no flag"
    (sole candidate -> local default -> error).

    `order` (#393) is DIFFERENT from every other param above: an absent
    value degrades to `"asc"` (the permissive default, back-compat), but a
    PRESENT-and-invalid value (neither `"asc"` nor `"desc"`) is reported
    back as `order_error` (a message string, `None` when `order` is valid)
    rather than silently degrading -- `_traces` turns a non-`None`
    `order_error` into a clean 400, unlike `since`/`limit`'s "malformed ->
    default" posture. The asymmetry is deliberate: a malformed `since`/
    `limit` is indistinguishable from "no opinion" (there's no sane string
    that means `since=<bogus>` on purpose), but `order=sideways` is
    unambiguously a caller mistake worth surfacing rather than guessing
    which direction was meant."""
    since = None
    turn = None
    limit = TRACES_DEFAULT_LIMIT
    assistant_flag = None
    order = "asc"
    order_error = None
    if query:
        since_values = query.get("since")
        if since_values:
            try:
                since = int(since_values[0])
            except (TypeError, ValueError):
                since = None
        turn_values = query.get("turn")
        if turn_values:
            turn = turn_values[0]
        limit_values = query.get("limit")
        if limit_values:
            try:
                limit = int(limit_values[0])
            except (TypeError, ValueError):
                limit = TRACES_DEFAULT_LIMIT
        assistant_values = query.get("assistant")
        if assistant_values:
            assistant_flag = assistant_values[0]
        order_values = query.get("order")
        if order_values:
            order = order_values[0]
            if order not in ("asc", "desc"):
                order_error = (
                    f"invalid order {order!r} (expected 'asc' or 'desc')"
                )
    if limit < 0:
        limit = 0
    return since, turn, min(limit, TRACES_MAX_LIMIT), assistant_flag, order, order_error


def _parse_tasks_query(query):
    """Parses `GET /assistant/tasks`'s `state`/`limit`/`assistant` query
    params into `(state, limit, assistant_flag, state_error)` -- mirrors
    `_parse_traces_query`'s exact shape: `limit`/`assistant` degrade
    permissively on malformed input (same as `since`/`limit` there),
    `state` behaves like `order` there -- absent is fine (`None`, no
    filter), but a PRESENT-and-invalid value (not one of `tasks.STATES`)
    is reported back as `state_error` for `_tasks` to turn into a clean
    400, rather than silently returning zero rows for a typo'd state
    name."""
    state = None
    limit = TASKS_DEFAULT_LIMIT
    assistant_flag = None
    state_error = None
    if query:
        state_values = query.get("state")
        if state_values:
            state = state_values[0]
            if state not in tasks.STATES:
                state_error = (
                    f"invalid state {state!r} (expected one of {list(tasks.STATES)})"
                )
        limit_values = query.get("limit")
        if limit_values:
            try:
                limit = int(limit_values[0])
            except (TypeError, ValueError):
                limit = TASKS_DEFAULT_LIMIT
        assistant_values = query.get("assistant")
        if assistant_values:
            assistant_flag = assistant_values[0]
    if limit < 0:
        limit = 0
    return state, min(limit, TASKS_MAX_LIMIT), assistant_flag, state_error
