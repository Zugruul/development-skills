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
import threading
import uuid
from datetime import datetime, timezone

from assistant import (adapters, capability_index, default_store, digest as digest_module,
                        discovery, distill, observability, selection_store, tasks, turns)
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
                    # transition also lands as a trace event. `executors`
                    # is deliberately empty here: no real task kind ships
                    # with THIS task (AST-070 registers the first one) --
                    # an enqueued kind with no executor fails specifically
                    # and immediately rather than hanging.
                    # AST-067 (§12.4, issue #342): also hands it
                    # `self._repos_getter` (same live getter capability_index's
                    # own slot already takes) so `run_worker` can reconcile
                    # every currently-known root's leftover started/progress
                    # rows ONCE at startup -- see tasks.run_worker's docstring's
                    # "Restart reconciliation" section. `resolvers` is
                    # deliberately empty for the same reason `executors` is:
                    # no real task kind's remote-poll logic ships with THIS
                    # task either (AST-070 registers the first resolver
                    # alongside its first executor); an in-flight row whose
                    # kind has no resolver becomes `orphaned`, specifically
                    # and immediately, same as the no-executor case.
                    thread = threading.Thread(
                        target=tasks.run_worker,
                        args=(self.queues["tasks"], stop_event),
                        kwargs={"traces_queue": self.queues["traces"], "repos_getter": self._repos_getter},
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
            if enabled:
                _root, host, port = enabled[0]
                self._metrics_server, self._metrics_thread = observability.start_metrics_server(
                    host, port, self._metrics_roots_provider)
            else:
                self._metrics_server = None
                self._metrics_thread = None

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
                result = turns.run_turn(section, roster_provider, None, session_state, message)
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
