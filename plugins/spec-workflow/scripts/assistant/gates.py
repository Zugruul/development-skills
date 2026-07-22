"""AST-017 -- SPEC-ASSISTANT.md Sec15 E1 numeric gates harness (issue #315).

Sec15 makes E2 (the overlay UX) a numbers-gated door: N1's p95 <= 15s
threshold is "the E2 unblock" -- the overlay only gets built once real
turns are proven fast enough to be usable. This module is the harness that
produces those numbers, CLI-runnable:

    python3 gates.py --mode stub --out /tmp/ast017-stub.json
    python3 gates.py --mode real --out docs/gates/ast-e1-results.json \\
        --root <dogfood-repo-root> --brain-role dev

TWO MODES (this is the whole design):
  --mode stub  (CI, merge-gating, section-assistant-gates.sh) -- every gate
      runs against the stub provider binary (tests/fixtures/stub-codex).
      This proves the HARNESS works: timing plumbing, percentile/variance
      math, marker-barrier kill/recovery, bounded-failure detection -- NOT
      the real numbers. Every stub-mode gate builds its own hermetic,
      throwaway fixture repo (tempdir) and never touches this repo's real
      assistant state or a real provider CLI.
  --mode real  (dogfood, manual/orchestrator-invoked ONLY -- never CI) --
      N1 drives `n_turns` REAL turns through POST /assistant/chat against
      whatever provider `--root`'s assistant: section configures (this
      machine's authenticated codex/claude CLIs, subscription-only per
      Sec17.1); N2 runs brain.recall against `--root`'s REAL
      `--brain-role` brain with the query-embed cache; N5 runs a REAL
      provider CLI pointed at an isolated, logged-out CODEX_HOME (AST-011's
      isolation makes this cheap and network-cost-free-ish -- an
      auth-check failure, not a completion). N3 and N4 are mechanism/
      invariant checks (HTTP/thread contention isolation, engine+store
      crash-recovery) whose PROVIDER identity is incidental to what they
      assert, so both modes drive their "turn in flight" load through the
      stub CLI regardless of --mode (documented choice -- see run_n3/
      run_n4's own docstrings): what N3/N4 test is provider-agnostic, and
      the stub gives a genuinely deterministic in-flight window a real
      CLI's variable latency cannot.

Results shape (written to --out): {"mode", "ts", "gates": {"N1": {...},
"N2": {...}, ...}}. Each gate's dict always carries "passed": bool against
its documented threshold (module-level constants below, each with its own
assertion in section-assistant-gates.sh per the defaults-need-own-tests
lesson) plus the raw samples that produced it -- "results recorded" per the
AST-017 acceptance criteria means the raw numbers travel with the verdict,
not just the verdict.

`--ts` is injected (defaults to a real now() only when this is run by a
human interactively) so every result carries a caller-controlled timestamp
-- no bare `datetime.now()`/`Date.now()` in any TESTED path; only main()'s
CLI default touches the wall clock, and section-assistant-gates.sh always
passes --ts explicitly.

DOCUMENTED GAP (tool-use-rate, Sec15 N1): adapters.complete() (codex.py/
claude.py) returns only {text, usage, timings} -- no raw per-event stream
-- so a tool/agentic-use signal cannot be read off an adapter's return
value without changing adapter/turn behavior, which is out of scope for
this harness (it OBSERVES the pipeline, per the task brief, it does not
change engine/turns/adapter behavior). Stub mode proves the COUNTING
mechanism instead, via a side-channel the stub CLI writes for itself (see
fixtures/stub-codex/codex's own docstring: CODEX_STUB_TOOL_EVENT_TURNS /
CODEX_STUB_TOOL_EVENTS_FILE) -- ground truth of which scripted invocations
carried a tool-shaped event, independent of what the (unmodified) adapter
chooses to surface. Real mode has no equivalent instrumentation hook for a
real provider CLI and reports tool_use_rate=None with this same gap noted
in the result, rather than a fabricated number. A follow-up task (adapter
raw-event pass-through) is the real fix; flagged here, not silently routed
around.
"""
import argparse
import json
import math
import os
import shlex
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import types
import urllib.error
import urllib.request
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))            # .../scripts/assistant
SCRIPTS_DIR = os.path.dirname(HERE)                           # .../scripts
PLUGIN_DIR = os.path.dirname(SCRIPTS_DIR)                     # plugins/spec-workflow
NEURAL_VIEW = os.path.join(SCRIPTS_DIR, "neural-view.py")
DEFAULT_STUB_CODEX_DIR = os.path.join(PLUGIN_DIR, "tests", "fixtures", "stub-codex")

if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)  # so `import brain` / `from assistant import ...` work when run standalone

from assistant import adapters  # noqa: E402  -- import-time is subprocess-free (Sec17.1), see adapters.py's own docstring

# --------------------------------------------------------------- Sec15 thresholds
# Each constant gets its own assertion in section-assistant-gates.sh
# (defaults-need-own-tests) -- these are the literal numbers Sec15 gates on.

N1_P95_MAX_SECONDS = 15.0   # Sec15 N1: "p95 <= 15s or E2 is blocked"
N2_P95_MAX_MS = 300.0       # Sec15 N2: "recall p95 incl. embedding hop < 300ms (with cache)"

# Sec15 leaves N3's "measurably degrade" undefined -- documented choice (see
# run_n3's docstring for the full reasoning): loaded p95 / baseline p95 must
# stay under this factor.
N3_DEGRADATION_FACTOR_MAX = 3.0

# Sec15 N5 "bounded-time": elapsed must stay under the adapter's own mandatory
# timeout (Sec8.5) plus this margin, which covers process-spawn/HTTP-
# round-trip overhead outside the CLI's own internal timeout clock.
N5_TIMEOUT_MARGIN_SECONDS = 5.0

# N1's documented tool-use-event proof point (stub mode only, see this
# module's docstring GAP note): the scripted invocation ordinal (1-based,
# from CODEX_STUB_INVOCATION_COUNTER_FILE) that fires a tool-shaped event.
N1_STUB_TOOL_EVENT_TURN = 5

# N4's grace period for a real (uninstrumentable) provider CLI: no marker
# file is available for a real binary, so real mode waits this long after
# firing the turn before sending SIGKILL, betting on a real completion
# taking longer than this to land. Documented tradeoff, not determinism --
# stub mode's marker-barrier is what's actually deterministic (see run_n4).
N4_REAL_MODE_GRACE_SECONDS = 1.5


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


# ------------------------------------------------------------------- percentile/stats


def _percentile(samples, pct):
    """Nearest-rank percentile (documented choice -- stdlib-only, no numpy):
    for a sorted list of n samples, the p-th percentile is the
    ceil(p/100 * n)-th smallest value (1-indexed, clamped to [1, n]). This
    is the same convention `statistics.quantiles(..., method="inclusive")`
    approximates for small n, but implemented directly so the exact rule is
    visible and testable without depending on statistics module version
    quirks across the Python versions this repo supports."""
    if not samples:
        return None
    data = sorted(samples)
    if len(data) == 1:
        return data[0]
    rank = math.ceil(pct / 100.0 * len(data))
    rank = max(1, min(len(data), rank))
    return data[rank - 1]


def _stats(samples):
    """p50/p95/variance/mean over `samples`. Variance is POPULATION variance
    (statistics.pvariance, documented choice): each gate's sample set IS the
    entire population under measurement for that run (a fixed N1 20-turn
    session, a fixed N2 sample count) -- there is no larger unobserved
    population this run is estimating, so population variance (divide by n)
    is the correct statistic, not the sample-variance Bessel correction
    (divide by n-1) meant for inferring an unknown population from a
    subset."""
    if not samples:
        return {"n": 0, "p50": None, "p95": None, "variance": None, "mean": None}
    return {
        "n": len(samples),
        "p50": _percentile(samples, 50),
        "p95": _percentile(samples, 95),
        "variance": statistics.pvariance(samples) if len(samples) > 1 else 0.0,
        "mean": statistics.fmean(samples),
    }


# ------------------------------------------------------------------- fixture repo


def _write_fixture_repo(root, name="gatesbot"):
    """A marker'd repo with a structurally valid, enabled assistant: section
    wired to the openai/codex provider -- mirrors section-assistant-
    engine.sh's ae_repo / section-assistant-terminal.sh's at_repo so the
    fixture shape stays consistent with the rest of the assistant test
    suite."""
    claude = os.path.join(root, ".claude")
    os.makedirs(claude, exist_ok=True)
    with open(os.path.join(claude, ".neural-network"), "w", encoding="utf-8") as fh:
        fh.write("# neural-network\n")
    with open(os.path.join(claude, "project.yaml"), "w", encoding="utf-8") as fh:
        fh.write(
            "schemaVersion: 2\n"
            "assistant:\n"
            "    version: 1\n"
            "    enabled: true\n"
            f"    names: [{name}]\n"
            "    systemPrompt: |\n"
            f"        You are {name}.\n"
            "    llm:\n"
            "        provider: openai\n"
            "        model: gpt-5.6-sol\n"
            "    capabilities:\n"
            "        codex:\n"
            "            enabled: true\n"
            "            provisioning:\n"
            "                bin: codex\n"
        )


def _stub_fixture_root():
    root = tempfile.mkdtemp(prefix="ast017-fixture-root-")
    _write_fixture_repo(root)
    return root


# ------------------------------------------------------------------- server lifecycle


def _free_port():
    """Binds an ephemeral port and releases it -- a TOCTOU-narrow but
    practically fine approach for a harness (Server.start's own 30x0.1s
    retry-poll of pid_alive() already tolerates a lost race by failing
    loudly, not hanging)."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Server:
    """Spawns/kills/restarts ONE neural-view.py server for this harness's
    own exclusive use -- own NEURAL_VIEW_STATE tempdir, own random port,
    never the caller's real ~/.claude/neural-view state (Sec17.7: assistant
    local state is never shared with a real running instance a human might
    also have open)."""

    def __init__(self, root, env_extra=None, scan=None):
        self.root = root
        self.scan = scan
        self.state_dir = tempfile.mkdtemp(prefix="ast017-state-")
        self.port = _free_port()
        self.env_extra = dict(env_extra or {})
        self.env = None

    def _build_env(self):
        env = dict(os.environ)
        env.update(self.env_extra)
        env["NEURAL_VIEW_STATE"] = self.state_dir
        env["NEURAL_VIEW_PORT"] = str(self.port)
        return env

    def start(self, timeout=15.0):
        env = self._build_env()
        argv = [sys.executable, NEURAL_VIEW, "start"]
        argv += ["--scan", self.scan] if self.scan else ["--dir", self.root]
        out = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=timeout)
        expect = f"RUNNING http://127.0.0.1:{self.port}"
        if expect not in out.stdout:
            raise RuntimeError(
                f"gates harness: neural-view failed to start: stdout={out.stdout!r} stderr={out.stderr!r}"
            )
        self.env = env

    def url(self, path):
        return f"http://127.0.0.1:{self.port}{path}"

    def pid(self):
        with open(os.path.join(self.state_dir, "pid"), encoding="utf-8") as fh:
            return int(fh.read().strip())

    def stop(self, timeout=15.0):
        if self.env is None:
            return
        try:
            subprocess.run([sys.executable, NEURAL_VIEW, "stop"], env=self.env,
                            capture_output=True, text=True, timeout=timeout)
        except (subprocess.SubprocessError, OSError):
            pass

    def cleanup(self):
        shutil.rmtree(self.state_dir, ignore_errors=True)


def _http(method, url, body=None, timeout=30.0):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Content-Type": "application/json"} if data is not None else {}
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        try:
            return exc.code, json.loads(exc.read().decode("utf-8"))
        except ValueError:
            return exc.code, {}


def _wait_for_file(path, timeout=10.0, interval=0.02):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if os.path.exists(path):
            return True
        time.sleep(interval)
    return os.path.exists(path)


def _stub_env(extra=None):
    env = {
        "PATH": DEFAULT_STUB_CODEX_DIR + os.pathsep + os.environ.get("PATH", ""),
        "CODEX_STUB_MODE": "ok",
    }
    env.update(extra or {})
    return env


# ------------------------------------------------------------------------------ N1


def run_n1(mode, *, root=None, n_turns=20, ts=None):
    """Sec15 N1: scripted `n_turns`-turn session; records p50/p95/variance
    and harness tool-use rate; p95 <= N1_P95_MAX_SECONDS or E2 is blocked.

    Both modes drive turns identically -- real POST /assistant/chat calls
    against a real neural-view server, timed client-side end-to-end (the
    same latency an overlay/terminal caller would see). Stub mode swaps
    ONLY the provider CLI on PATH; it never fakes the HTTP layer, the
    engine, or turns.py -- see this module's docstring for why that proves
    plumbing, not real numbers.
    """
    if mode not in ("stub", "real"):
        raise ValueError(f"unknown mode: {mode!r}")

    owns_root = mode == "stub"
    fixture_root = _stub_fixture_root() if owns_root else root
    if fixture_root is None:
        raise ValueError("real mode requires --root")

    tool_events_file = None
    counter_file = None
    env_extra = {}
    if mode == "stub":
        tool_events_file = tempfile.mktemp(prefix="ast017-n1-tool-events-")
        counter_file = tempfile.mktemp(prefix="ast017-n1-counter-")
        env_extra = _stub_env({
            "CODEX_STUB_INVOCATION_COUNTER_FILE": counter_file,
            "CODEX_STUB_TOOL_EVENT_TURNS": str(N1_STUB_TOOL_EVENT_TURN),
            "CODEX_STUB_TOOL_EVENTS_FILE": tool_events_file,
        })

    server = Server(fixture_root, env_extra=env_extra)
    latencies = []
    try:
        server.start()
        for i in range(1, n_turns + 1):
            t0 = time.monotonic()
            status, payload = _http("POST", server.url("/assistant/chat"), {"message": f"gates n1 turn {i}"})
            latencies.append(time.monotonic() - t0)
            if status != 200:
                raise RuntimeError(f"N1 turn {i} failed: HTTP {status} {payload}")
    finally:
        server.stop()
        server.cleanup()
        if owns_root:
            shutil.rmtree(fixture_root, ignore_errors=True)

    tool_use_rate = None
    tool_use_note = None
    if mode == "stub":
        fired = 0
        if tool_events_file and os.path.exists(tool_events_file):
            with open(tool_events_file, encoding="utf-8") as fh:
                fired = sum(1 for line in fh if line.strip().endswith("TOOL"))
        tool_use_rate = fired / n_turns if n_turns else None
        for p in (tool_events_file, counter_file):
            if p and os.path.exists(p):
                os.remove(p)
    else:
        tool_use_note = (
            "real-mode tool-use-rate not measured: adapters.complete() returns only "
            "{text, usage, timings}, no raw per-event stream, and no equivalent "
            "side-channel exists for a real provider CLI -- see gates.py module "
            "docstring's DOCUMENTED GAP."
        )

    stats = _stats(latencies)
    passed = stats["p95"] is not None and stats["p95"] <= N1_P95_MAX_SECONDS
    return {
        "gate": "N1",
        "mode": mode,
        "n_turns": n_turns,
        "latencies_seconds": latencies,
        "p50_seconds": stats["p50"],
        "p95_seconds": stats["p95"],
        "variance_seconds2": stats["variance"],
        "mean_seconds": stats["mean"],
        "threshold_p95_seconds": N1_P95_MAX_SECONDS,
        "tool_use_rate": tool_use_rate,
        "tool_use_note": tool_use_note,
        "passed": passed,
        "ts": ts,
    }


# ------------------------------------------------------------------------------ N2

_STUB_EMBED_SCRIPT = (
    "import sys, json, hashlib\n"
    "for line in sys.stdin:\n"
    "    line = line.rstrip(\"\\n\")\n"
    "    h = hashlib.sha256(line.encode(\"utf-8\")).digest()\n"
    "    vec = [b / 255.0 for b in h[:16]]\n"
    "    print(json.dumps(vec))\n"
)


def _n2_real_queries(n):
    """A small, deterministic set of realistic-shaped queries, cycled to
    fill `n` samples -- roughly half repeat within the query-embed cache's
    TTL, so cache_hit_rate is a meaningful, non-degenerate number rather
    than always 0 or always 1."""
    base = [
        "kill -9 mid write torn line tolerance",
        "board move guard mechanical enforcement",
        "gate run bash strict mode section",
        "worktree per task merge to main",
        "recall p95 embedding hop cache",
    ]
    return [base[i % len(base)] for i in range(n)]


def run_n2(mode, *, root=None, role=None, n_samples=30, ts=None):
    """Sec15 N2: recall p95 including the embedding hop, WITH the
    query-embed cache, < N2_P95_MAX_MS.

    Uses `turns.make_default_recall` wrapped in `turns.QueryEmbedCache` --
    the EXACT seam AST-013's run_turn uses in production (Sec9.1) -- so
    this measures the real code path, not a reimplementation of it.

    DOCUMENTED SIDE EFFECT (review r2): in --mode real this genuinely
    perturbs the REAL brain -- brain.recall() bumps fires/last on traversed
    links (load_links -> spread -> save_links, unconditionally). Acceptable
    for a manual, orchestrator-invoked dogfood measurement (the bumps are
    ordinary recall activity), but it is a write, not a read -- do not run
    real N2 in any context where the brain must stay untouched.

    Stub mode substitutes a small hermetic fixture brain (a handful of
    minted notes, indexed via brain.py's `BRAIN_EMBED_CMD` override pointed
    at a fast deterministic embedder script) for the real dev brain, so CI
    never depends on the real corpus or a real embeddings capability --
    this proves the timing/cache/threshold PLUMBING, not real recall
    latency (see module docstring).
    """
    if mode not in ("stub", "real"):
        raise ValueError(f"unknown mode: {mode!r}")

    import brain as brain_module
    from assistant import turns as turns_module

    cleanup_paths = []
    old_embed_cmd = os.environ.get("BRAIN_EMBED_CMD")
    try:
        if mode == "stub":
            root = tempfile.mkdtemp(prefix="ast017-n2-root-")
            cleanup_paths.append(root)
            role = role or "gatesbrain"
            identities = os.path.join(root, ".claude", "identities")
            os.makedirs(identities, exist_ok=True)
            for i in range(6):
                brain_module.mint(
                    identities, role, f"fixture-note-{i}", root,
                    f"Fixture note body number {i} about topic-{i % 3}.",
                    tags=f"topic-{i % 3}", paths="**",
                )
            embed_script = tempfile.mktemp(prefix="ast017-embed-", suffix=".py")
            cleanup_paths.append(embed_script)
            with open(embed_script, "w", encoding="utf-8") as fh:
                fh.write(_STUB_EMBED_SCRIPT)
            os.environ["BRAIN_EMBED_CMD"] = f"{shlex.quote(sys.executable)} {shlex.quote(embed_script)}"
            ns = types.SimpleNamespace(role=role, rebuild=True)
            brain_module.cmd_index(identities, ns)
            # review r1: cycle a small repeated set (mirroring _n2_real_queries) so
            # stub mode genuinely exercises the cache-hit path -- distinct-per-i
            # queries made cache_hit_rate degenerately 0.0 while the section label
            # implied the hit path ran.
            queries = [f"topic-{i % 3} fixture question" for i in range(n_samples)]
        else:
            if not root or not role:
                raise ValueError("real mode requires --root and --brain-role")
            identities = os.path.join(root, ".claude", "identities")
            queries = _n2_real_queries(n_samples)

        recall_fn = turns_module.make_default_recall(identities, root, role=role, k=8 if mode == "real" else 4)
        cache = turns_module.QueryEmbedCache()
        latencies_ms = []
        hits = 0
        for q in queries:
            t0 = time.monotonic()
            _, hit = cache.get_or_compute(q, recall_fn)
            latencies_ms.append((time.monotonic() - t0) * 1000.0)
            hits += 1 if hit else 0
    finally:
        if old_embed_cmd is None:
            os.environ.pop("BRAIN_EMBED_CMD", None)
        else:
            os.environ["BRAIN_EMBED_CMD"] = old_embed_cmd
        for p in cleanup_paths:
            if os.path.isdir(p):
                shutil.rmtree(p, ignore_errors=True)
            elif os.path.exists(p):
                os.remove(p)

    stats = _stats(latencies_ms)
    passed = stats["p95"] is not None and stats["p95"] <= N2_P95_MAX_MS
    return {
        "gate": "N2",
        "mode": mode,
        "n_samples": len(latencies_ms),
        "latencies_ms": latencies_ms,
        "p50_ms": stats["p50"],
        "p95_ms": stats["p95"],
        "variance_ms2": stats["variance"],
        "mean_ms": stats["mean"],
        "cache_hit_rate": (hits / len(latencies_ms)) if latencies_ms else None,
        "threshold_p95_ms": N2_P95_MAX_MS,
        "passed": passed,
        "ts": ts,
    }


# ------------------------------------------------------------------------------ N3


def _poll_latency_seconds(server):
    t0 = time.monotonic()
    _http("GET", server.url("/assistant/status"))
    return time.monotonic() - t0


def run_n3(mode, *, n_samples=20, ts=None):
    """Sec15 N3: a turn in flight + /graph rebuild concurrently SHALL NOT
    measurably degrade page polling.

    Methodology (documented choice -- Sec15 leaves both "page polling" and
    "measurably degrade" undefined): "page polling" = GET /assistant/status
    (the cheap, subprocess-free poll route a client hits repeatedly, per
    its own docstring in engine.py). "Load" = one long-running turn in
    flight concurrently with a background loop of GET /graph requests (the
    route that does the actual rebuild work, Sec5a) against the SAME
    server. Degradation is `loaded_p95 / baseline_p95`, must stay under
    N3_DEGRADATION_FACTOR_MAX (documented default 3x: baseline poll latency
    on an idle stub server is low-single-digit milliseconds, so even a
    generous 3x factor leaves wide headroom before it would be
    user-visible, while still catching an actual serialization regression,
    which shows up as an order-of-magnitude jump, not a 2-3x wobble).

    The "turn in flight" load generator always uses the stub CLI regardless
    of `mode` (documented choice): what this gate tests is HTTP/thread
    contention inside the engine (Sec5a's per-root chat lock, the worker
    registry, the HTTP request-thread pool), which is provider-agnostic --
    a real provider's variable latency would make the "in flight" window
    non-deterministic without adding anything this gate is meant to catch.
    `mode` is still recorded on the result for reporting symmetry with the
    other four gates.
    """
    fixture_root = _stub_fixture_root()
    graph_latencies = []
    # review r2: construct BEFORE try (n1's pattern) -- if Server.__init__
    # raises, the finally must not NameError on an unbound name and must
    # still clean the fixture root.
    server = Server(fixture_root, env_extra=_stub_env({"CODEX_STUB_SLEEP_SECONDS": "2"}))
    try:
        server.start()

        baseline = [_poll_latency_seconds(server) for _ in range(n_samples)]

        stop_flag = threading.Event()

        def _graph_loop():
            while not stop_flag.is_set():
                t0 = time.monotonic()
                _http("GET", server.url("/graph"))
                graph_latencies.append(time.monotonic() - t0)

        graph_thread = threading.Thread(target=_graph_loop, daemon=True)
        graph_thread.start()

        chat_thread = threading.Thread(
            target=lambda: _http("POST", server.url("/assistant/chat"), {"message": "n3 load turn"}),
            daemon=True,
        )
        chat_thread.start()
        time.sleep(0.1)  # let the turn actually enter flight before sampling starts

        loaded = [_poll_latency_seconds(server) for _ in range(n_samples)]

        chat_thread.join(timeout=30)
        stop_flag.set()
        graph_thread.join(timeout=5)
    finally:
        server.stop()
        server.cleanup()
        shutil.rmtree(fixture_root, ignore_errors=True)

    base_stats = _stats(baseline)
    load_stats = _stats(loaded)
    factor = (load_stats["p95"] / base_stats["p95"]) if base_stats["p95"] else None
    passed = factor is not None and factor <= N3_DEGRADATION_FACTOR_MAX
    return {
        "gate": "N3",
        "mode": mode,
        "baseline_samples_seconds": baseline,
        "loaded_samples_seconds": loaded,
        "baseline_p95_seconds": base_stats["p95"],
        "loaded_p95_seconds": load_stats["p95"],
        "degradation_factor": factor,
        "threshold_degradation_factor": N3_DEGRADATION_FACTOR_MAX,
        "graph_poll_count_during_load": len(graph_latencies),
        "passed": passed,
        "ts": ts,
    }


# ------------------------------------------------------------------------------ N4


def run_n4(mode, *, ts=None):
    """Sec15 N4: kill -9 the SERVER mid-turn -> restart: session resumes
    (history intact, Sec8.7), links.json + all sqlites uncorrupted.

    Marker-barrier deterministic kill (stub mode): the fixture server runs
    the stub codex CLI with CODEX_STUB_TURN_MARKER set and a long
    CODEX_STUB_SLEEP_SECONDS; the harness POSTs /assistant/chat in a
    background thread and polls for the marker file's appearance -- proof
    the provider CLI (and therefore the whole engine._chat critical
    section, Sec5a) has actually started the turn -- before SIGKILLing the
    SERVER process (not the stub child, which is simply orphaned and exits
    once its parent is gone; nothing asserts on it). One exchange is seeded
    and confirmed BEFORE the kill so "session resumes" has something
    concrete to resume.

    Real mode has no marker hook for an uninstrumentable real CLI --
    instead it waits N4_REAL_MODE_GRACE_SECONDS after firing the turn (a
    documented, non-deterministic tradeoff, see that constant's docstring)
    before sending SIGKILL. Like N3, the provider identity is incidental to
    what this gate asserts (engine/store crash-recovery, not provider
    behavior) -- `mode` only changes the barrier mechanism, not what gets
    checked afterward.
    """
    if mode not in ("stub", "real"):
        raise ValueError(f"unknown mode: {mode!r}")

    fixture_root = _stub_fixture_root()
    marker = tempfile.mktemp(prefix="ast017-n4-marker-")
    server = None
    marker_seen = False
    killed_pid = None
    try:
        server = Server(fixture_root, env_extra=_stub_env())
        server.start()

        pre_status, _pre_payload = _http("POST", server.url("/assistant/chat"), {"message": "pre-kill exchange"})
        pre_ok = pre_status == 200

        server.stop()
        interrupt_env = _stub_env({"CODEX_STUB_SLEEP_SECONDS": "30"})
        if mode == "stub":
            interrupt_env["CODEX_STUB_TURN_MARKER"] = marker
        server.env_extra = interrupt_env
        server.start()

        result_holder = {}

        def _turn():
            try:
                result_holder["response"] = _http(
                    "POST", server.url("/assistant/chat"), {"message": "mid-kill turn"}, timeout=40.0
                )
            except (urllib.error.URLError, OSError) as exc:
                # Expected on a real kill: the connection gets severed
                # mid-request. Recorded, never allowed to crash the harness.
                result_holder["error"] = str(exc)

        turn_thread = threading.Thread(target=_turn, daemon=True)
        turn_thread.start()

        if mode == "stub":
            marker_seen = _wait_for_file(marker, timeout=10.0)
        else:
            time.sleep(N4_REAL_MODE_GRACE_SECONDS)
            marker_seen = True  # grace-period barrier: "seen" means "we waited", not a real signal

        killed_pid = server.pid()
        os.kill(killed_pid, signal.SIGKILL)
        turn_thread.join(timeout=5)

        server.env_extra = _stub_env()
        server.start()

        hstatus, history_payload = _http("GET", server.url("/assistant/history"))
        history_ok = hstatus == 200 and any(
            ex.get("user") == "pre-kill exchange" for ex in history_payload.get("exchanges", [])
        )

        from assistant.store import SessionStore

        store = SessionStore(fixture_root)
        state = store.load_state()
        session_state_parses = isinstance(state, dict)
        hist = store.history(None)
        session_jsonl_parses_no_warnings = not hist["warnings"]

        links_json_ok = True  # vacuously true if absent -- see docstring
        links_path = os.path.join(fixture_root, ".claude", "identities", "assistant", "brain", "links.json")
        if os.path.isfile(links_path):
            try:
                with open(links_path, encoding="utf-8") as fh:
                    json.load(fh)
            except (OSError, ValueError):
                links_json_ok = False
    finally:
        if server is not None:
            server.stop()
            server.cleanup()
        shutil.rmtree(fixture_root, ignore_errors=True)
        if os.path.exists(marker):
            os.remove(marker)

    passed = bool(
        pre_ok and marker_seen and history_ok and session_state_parses
        and session_jsonl_parses_no_warnings and links_json_ok
    )
    return {
        "gate": "N4",
        "mode": mode,
        "pre_kill_exchange_ok": pre_ok,
        "marker_seen_before_kill": marker_seen,
        "killed_pid": killed_pid,
        "server_recovered": True,
        "history_intact_after_restart": history_ok,
        "session_state_parses": session_state_parses,
        "session_jsonl_parses_no_warnings": session_jsonl_parses_no_warnings,
        "links_json_parses_or_absent": links_json_ok,
        "passed": passed,
        "ts": ts,
    }


# ------------------------------------------------------------------------------ N5


def run_n5(mode, *, root=None, ts=None):
    """Sec15 N5: logged-out provider -> bounded-time, specific failure.

    "Bounded" = elapsed < adapters.DEFAULT_TIMEOUT_SECONDS +
    N5_TIMEOUT_MARGIN_SECONDS (the margin covers process-spawn/HTTP-
    round-trip overhead outside the CLI's own internal timeout clock, per
    that constant's docstring). "Specific" = the error names the failure
    mode (a login instruction), never a bare traceback or a generic 500.

    Stub mode: CODEX_STUB_MODE=auth reproduces codex's own real
    unauthenticated-run signature (corpus-sourced, see fixtures/
    stub-codex/codex's own docstring) through codex.py's REAL
    `_looks_like_auth_failure` classifier -- this exercises the real
    adapter code path; only the CLI it shells out to is fake.
    Real mode: a real provider CLI pointed at a freshly created, empty
    CODEX_HOME (AST-011's isolation makes an isolated home cheap to build)
    -- a genuinely logged-out state, no stub involved.
    """
    if mode not in ("stub", "real"):
        raise ValueError(f"unknown mode: {mode!r}")

    fixture_root = _stub_fixture_root() if mode == "stub" else root
    if fixture_root is None:
        raise ValueError("real mode requires --root")
    owns_root = mode == "stub"

    logged_out_home = None
    if mode == "stub":
        env_extra = _stub_env({"CODEX_STUB_MODE": "auth"})
    else:
        logged_out_home = tempfile.mkdtemp(prefix="ast017-n5-logged-out-home-")
        env_extra = {"CODEX_HOME": logged_out_home}

    # review r2: construct BEFORE try (see run_n3) so finally never
    # NameErrors and fixture/home cleanup always runs.
    server = Server(fixture_root, env_extra=env_extra)
    try:
        server.start()
        t0 = time.monotonic()
        status, payload = _http("POST", server.url("/assistant/chat"), {"message": "hi"}, timeout=90.0)
        elapsed = time.monotonic() - t0
    finally:
        server.stop()
        server.cleanup()
        if owns_root:
            shutil.rmtree(fixture_root, ignore_errors=True)
        if logged_out_home:
            shutil.rmtree(logged_out_home, ignore_errors=True)

    bound = adapters.DEFAULT_TIMEOUT_SECONDS + N5_TIMEOUT_MARGIN_SECONDS
    bounded = elapsed < bound
    error_message = payload.get("error") if isinstance(payload, dict) else None
    specific = status == 502 and isinstance(error_message, str) and "login" in error_message.lower()
    passed = bounded and specific
    return {
        "gate": "N5",
        "mode": mode,
        "elapsed_seconds": elapsed,
        "bound_seconds": bound,
        "http_status": status,
        "error_message": error_message,
        "bounded": bounded,
        "specific": specific,
        "passed": passed,
        "ts": ts,
    }


# ------------------------------------------------------------------------------ CLI

GATE_FUNCS = {"N1": run_n1, "N2": run_n2, "N3": run_n3, "N4": run_n4, "N5": run_n5}


def run_gates(mode, gates, *, root=None, brain_role=None, n_turns=20, n_recall_samples=30, ts=None):
    """Runs the requested subset of gates (in Sec15's N1..N5 order,
    regardless of the order requested) and returns the aggregate results
    dict main() writes to --out."""
    ts = ts or _now_iso()
    ordered = [g for g in ("N1", "N2", "N3", "N4", "N5") if g in gates]
    results = {}
    error = None
    for name in ordered:
        # review r2: a gate crashing must not discard the gates already paid
        # for (real mode: 20 real turns) -- record the partial results plus a
        # per-gate error entry and stop, honestly marked incomplete.
        try:
            if name == "N1":
                results[name] = run_n1(mode, root=root, n_turns=n_turns, ts=ts)
            elif name == "N2":
                results[name] = run_n2(mode, root=root, role=brain_role, n_samples=n_recall_samples, ts=ts)
            elif name == "N3":
                results[name] = run_n3(mode, n_samples=20, ts=ts)
            elif name == "N4":
                results[name] = run_n4(mode, ts=ts)
            elif name == "N5":
                results[name] = run_n5(mode, root=root, ts=ts)
        except Exception as e:  # noqa: BLE001 -- recorded, not swallowed
            results[name] = {"passed": False, "error": f"{type(e).__name__}: {e}"}
            error = e
            break
    out = {"mode": mode, "ts": ts, "gates": results}
    if error is not None:
        out["incomplete"] = True
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description="AST-017 SPEC-ASSISTANT.md Sec15 E1 gates harness")
    parser.add_argument("--mode", choices=("stub", "real"), default="stub")
    parser.add_argument("--out", required=True, help="path to write the results JSON")
    parser.add_argument("--ts", default=None,
                         help="ISO timestamp injected into every result (determinism); "
                              "defaults to a real now() only for an interactive run")
    parser.add_argument("--gates", default="N1,N2,N3,N4,N5",
                         help="comma-separated subset of N1..N5 to run")
    parser.add_argument("--root", default=None,
                         help="real mode: repo root N1/N2/N5 drive turns/recall against "
                              "(ignored in stub mode -- every stub gate builds its own fixture)")
    parser.add_argument("--brain-role", default=None,
                         help="real mode: identity role whose brain N2 queries (e.g. dev)")
    parser.add_argument("--n-turns", type=int, default=20)
    parser.add_argument("--n-recall-samples", type=int, default=30)
    args = parser.parse_args(argv)

    gates = [g.strip().upper() for g in args.gates.split(",") if g.strip()]
    unknown = [g for g in gates if g not in GATE_FUNCS]
    if unknown:
        parser.error(f"unknown gate(s): {', '.join(unknown)} (valid: {', '.join(sorted(GATE_FUNCS))})")

    results = run_gates(
        args.mode, gates, root=args.root, brain_role=args.brain_role,
        n_turns=args.n_turns, n_recall_samples=args.n_recall_samples, ts=args.ts,
    )

    # review r2: atomic tmp+rename (this file gets COMMITTED as the E2
    # verdict artifact -- a torn write must be impossible), and a clean
    # one-line error on an unwritable path instead of a traceback.
    try:
        out_dir = os.path.dirname(os.path.abspath(args.out))
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".gates-out-", dir=out_dir or ".")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(results, fh, indent=2, sort_keys=True)
                fh.write("\n")
            os.replace(tmp, args.out)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
    except OSError as e:
        print(f"gates: cannot write --out {args.out}: {e}", file=sys.stderr)
        return 2

    all_passed = all(g["passed"] for g in results["gates"].values())
    for name, g in results["gates"].items():
        verdict = "PASS" if g["passed"] else "FAIL"
        print(f"{name}: {verdict}")
    print(f"wrote {args.out}")
    return 0 if all_passed else 1


if __name__ == "__main__":
    sys.exit(main())
