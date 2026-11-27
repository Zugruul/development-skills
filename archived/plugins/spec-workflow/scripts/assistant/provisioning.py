"""Provisioning checks: TTL-cached, argv-array subprocess execution
(SPEC-ASSISTANT.md Sec11.1, Sec11.4, AST-062, issue #337,
docs/design/ast-E6.md).

Per Sec11.1 a capability.yaml's `provisioning` block carries `check` (an
ARGV ARRAY, never a shell string -- Sec17.3) and `ttlSeconds`. Per Sec11.4
"Unprovisioned-but-enabled skills SHALL appear in the roster as unavailable
with the reason; THE SYSTEM SHALL never present an unavailable ability as
usable." This module is the checker AST-061's `capability_index.
compile_index` already carries an injectable `provisioning_checker` seam
for (defaulting, until now, to "unknown/assumed ok") -- it runs the real
check and classifies the outcome into a specific, human-actionable reason
string.

Per docs/design/ast-E6.md ("Pure library: no HTTP, no subprocess spawning
of its own -- provisioning checks and invoke both go through adapters.py's
existing sandboxed-subprocess path") the actual subprocess call goes
through `adapters.invoke_cli`: the SAME argv-only (Sec17.3), mandatory-
timeout (Sec8.5-equivalent posture) primitive every provider adapter
already funnels through, so a missing binary or a timeout is caught in
exactly one place rather than reimplemented here.

Reason-string shapes (pinned by section-capability-provisioning.sh):
  - nonzero exit:   "provisioning check exited <rc>: <stderr tail>" (the
    stderr tail is omitted, per the colon, only when stderr is empty).
  - missing binary: "provisioning check binary not found: <argv[0]>" -- the
    argv[0] that could not be executed is extracted from adapters.NotFound
    (issue #408's OSError-taxonomy posture) and reworded to stand on its
    own, rather than embedding adapters.NotFound's own message verbatim
    (which talks about a "provider CLI", not a provisioning check, and
    would otherwise land that wording in the persona prompt via Sec11.4's
    roster).
  - timeout:        "provisioning check timed out after <N>s: <argv joined>"

Constraint -- provisioning.check argv resolution: `run_check`/`ProvisioningChecker`
do not pass a `cwd` to `adapters.invoke_cli` (the `(name, argv)` cache key
deliberately carries no repo root, and threading one through would change
execution semantics, which is out of scope here). A capability's
`provisioning.check` argv[0] is therefore resolved exactly like any other
subprocess call with no explicit `cwd`: via `PATH` if bare, or must be an
absolute path. A RELATIVE path (e.g. `["./bin/check"]`) resolves against
the assistant engine process's own working directory, NOT against the
skill's directory -- `skill_dir` is accepted by `ProvisioningChecker.
__call__` (matching `capability_index.compile_index`'s exact seam shape)
but is not otherwise used by this module.

Library:
    run_check(argv, timeout=DEFAULT_CHECK_TIMEOUT_SECONDS) ->
        (provisioned_ok: bool, unavailable_reason: str | None)
        One-shot, uncached check run. Never raises.

    ProvisioningChecker(timeout=..., clock=time.monotonic, run=run_check)
        A `provisioning_checker(name, capability, skill_dir) ->
        (provisioned_ok, unavailable_reason)` callable
        (`capability_index.compile_index`'s exact seam shape) backed by a
        per-instance TTL cache.

        Cache key: `(name, tuple(capability.provisioning["check"]))` --
        per docs/design/ast-E6.md's "cache key is the capability name +
        its provisioning check's argv, invalidated on config change same
        as the index itself": editing a skill's `provisioning.check` argv
        changes the key outright, so the OLD argv's cached verdict is
        simply never looked up again for the new one. Toggling a skill's
        `enabled` flag needs no invalidation here at all -- `compile_index`
        never calls this checker for a disabled skill in the first place
        (Sec11.2: disabled is invisible, checked upstream of provisioning).
        `ttlSeconds` is read fresh from `capability.provisioning` on every
        call (never captured into the cached entry), so an operator
        widening/narrowing a capability's TTL takes effect on the very
        next call, not just the next cache miss. Malformed/legacy
        `ttlSeconds` (non-int, or a bool -- `isinstance(True, int)` is
        `True`, the house bool-before-int-guard lesson) degrades to "TTL
        0", i.e. always recheck -- never a crash, never a bogus 1-second
        cache from a stray `ttlSeconds: true`.

        Negative caching decision (AST-062's brief explicitly asks this be
        made deliberately, citing assistant/preflight.py's precedent):
        UNLIKE preflight.py's auth-probe cache (which NEVER caches a FAIL,
        because a human running `codex login` right now expects the very
        next preflight to see it -- preflight is invoked per human action),
        a provisioning-check FAILURE **is** cached here, for the full TTL,
        exactly like a success. Rationale: `capability_index.compile_index`
        is driven by `run_worker`'s poll loop (Sec11.3: "never per-turn",
        polled every `DEFAULT_INDEX_POLL_SECONDS`), not by a human action --
        caching only the positive path would mean a not-yet-provisioned
        capability (e.g. issue #424's whisper sidecar, still warming up)
        reruns its check subprocess on EVERY poll tick until it happens to
        pass, which is exactly the "flapping check hammers the system"
        failure mode this task's brief warns against. TTL bounds staleness
        symmetrically either way: a newly-fixed capability is recognized as
        available again within `ttlSeconds`, and a newly-broken one is
        recognized as unavailable within `ttlSeconds` -- Sec11.4 asks for
        an HONEST roster, not an instantaneous one.

real_provisioning_checker -- the module-level `ProvisioningChecker()`
    singleton `capability_index.compile_index` imports (lazily, so
    importing capability_index.py alone never imports this module's
    adapters.py/subprocess dependency chain) as its new default
    `provisioning_checker`, replacing AST-061's always-ok placeholder.
    Being a plain module-level singleton, its cache persists across
    `compile_index` calls within one process -- exactly what makes the TTL
    meaningful across repeated recompiles, per docs/design/ast-E6.md's
    "Provisioning checks are TTL-cached, not per-turn" decision.
"""
import time

from assistant import adapters

DEFAULT_CHECK_TIMEOUT_SECONDS = 10

# How much of a failing check's stderr rides along in the reason string --
# the LAST non-empty line, itself capped to this many characters, so one
# runaway line can never blow up the roster's reason text.
_STDERR_TAIL_CHARS = 240


def _stderr_tail(stderr):
    text = (stderr or "").strip()
    if not text:
        return ""
    tail = text.splitlines()[-1]
    if len(tail) > _STDERR_TAIL_CHARS:
        tail = tail[-_STDERR_TAIL_CHARS:]
    return tail


def run_check(argv, timeout=DEFAULT_CHECK_TIMEOUT_SECONDS):
    """Runs one `provisioning.check` argv array via `adapters.invoke_cli`.
    Returns `(provisioned_ok, unavailable_reason)`; never raises --
    `adapters.invoke_cli`'s own `AdapterError` taxonomy (`Timeout`,
    `NotFound`) is caught here and turned into a specific, named reason
    (see module docstring for the exact shapes)."""
    try:
        result = adapters.invoke_cli(list(argv), timeout=timeout)
    except adapters.Timeout:
        return False, f"provisioning check timed out after {timeout}s: {' '.join(argv)}"
    except adapters.NotFound as exc:
        # adapters.NotFound's own message says "provider CLI '<argv[0]>'
        # could not be executed: <os error>" -- accurate for a provider
        # adapter call, but a provisioning check is not a provider CLI, and
        # this reason string lands verbatim in the persona prompt (Sec11.4's
        # roster). Reword it to stand on its own, using argv[0] directly
        # (rather than re-parsing it out of exc's message) and the
        # underlying OS error (exc's __cause__, the FileNotFoundError/
        # PermissionError/NotADirectoryError adapters.invoke_cli wrapped)
        # for the detail.
        detail = exc.__cause__ if exc.__cause__ is not None else exc
        return False, f"provisioning check binary not found: {argv[0]} ({detail})"

    if result.returncode != 0:
        reason = f"provisioning check exited {result.returncode}"
        tail = _stderr_tail(result.stderr)
        if tail:
            reason += f": {tail}"
        return False, reason

    return True, None


def _ttl_seconds(provisioning):
    ttl = provisioning.get("ttlSeconds") if isinstance(provisioning, dict) else None
    # bool-before-int-guard (house lesson): isinstance(True, int) is True,
    # so the bool check MUST precede the int check or `ttlSeconds: true`
    # would be silently treated as a 1-second TTL.
    if isinstance(ttl, bool) or not isinstance(ttl, int):
        return 0
    return ttl


class ProvisioningChecker:
    """TTL-cached `provisioning_checker(name, capability, skill_dir) ->
    (provisioned_ok, unavailable_reason)` -- see module docstring for the
    cache-key, invalidation, and negative-caching rationale, and for the
    "argv must be PATH-resolvable or absolute" constraint (`skill_dir` is
    accepted, to match the seam shape, but is not used to resolve `argv`)."""

    def __init__(self, timeout=DEFAULT_CHECK_TIMEOUT_SECONDS, clock=time.monotonic, run=run_check):
        # time.monotonic, never time.time: a backwards wall-clock jump (NTP
        # correction, DST, manual clock set) would make `now - cached_at`
        # negative, which satisfies `< ttl` and serves a stale verdict
        # indefinitely -- monotonic never runs backwards.
        self._timeout = timeout
        self._clock = clock
        self._run = run
        # (name, argv_tuple) -> (provisioned_ok, unavailable_reason, cached_at)
        self._cache = {}

    def clear(self):
        """Drops every cached verdict -- exposed for callers (and tests)
        that need to force a fresh check regardless of TTL."""
        self._cache.clear()

    def __call__(self, name, capability, skill_dir):
        """Runs (or serves a cached verdict for) `capability`'s
        `provisioning.check`. `skill_dir` is accepted only to match
        `capability_index.compile_index`'s seam shape -- no `cwd` is passed
        to `adapters.invoke_cli`, so `check`'s argv[0] resolves exactly like
        any other subprocess call with no explicit `cwd`: via `PATH` if
        bare, or must be absolute. A RELATIVE path (e.g. `["./bin/check"]`)
        is NOT resolved against `skill_dir` -- it resolves against the
        assistant engine process's own working directory instead."""
        provisioning = getattr(capability, "provisioning", None)
        provisioning = provisioning if isinstance(provisioning, dict) else {}
        check = provisioning.get("check")
        if not isinstance(check, list) or not check:
            # Structurally this should never happen -- capability_index.
            # load_capability/validate_capability already rejects a
            # capability.yaml whose provisioning.check isn't a non-empty
            # argv array before compile_index ever calls this checker --
            # but never crash the index compile over a defensive gap.
            return False, "provisioning.check is missing or not an argv array"

        argv = tuple(check)
        key = (name, argv)
        ttl = _ttl_seconds(provisioning)
        now = self._clock()

        cached = self._cache.get(key)
        if cached is not None:
            ok, reason, cached_at = cached
            if ttl > 0 and (now - cached_at) < ttl:
                return ok, reason

        ok, reason = self._run(check, timeout=self._timeout)
        self._cache[key] = (ok, reason, now)
        return ok, reason


# The real default `capability_index.compile_index` wires in (lazily
# imported there, per that module's "pure library" posture) -- a
# module-level singleton so its cache persists across compile_index calls
# within one process, which is what makes the TTL meaningful at all.
real_provisioning_checker = ProvisioningChecker()
