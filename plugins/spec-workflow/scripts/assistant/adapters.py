"""Provider adapter contract (SPEC-ASSISTANT.md Sec5a, Sec8.1, Sec8.4, Sec8.5,
Sec17.1-Sec17.3).

AST-011 fills in the contract AST-010 stubbed: `complete(context) ->
{text, usage, timings}`, one stateless provider-CLI invocation per turn
(Sec8.1). Every adapter (codex.py here; claude.py is AST-012) funnels its
subprocess call through `invoke_cli()` below so the argv-array-only
(Sec17.3), mandatory-timeout (Sec8.5), and structured-error (Sec8.5)
invariants are enforced in exactly one place instead of per-adapter.

Error taxonomy (Sec8.5): the provider CLI exiting nonzero, timing out, or
emitting output the adapter cannot parse SHALL surface a bounded-time,
specific error -- never a bare stack trace or an indefinite hang. An
auth-expired state instructs the login command (`codex login` for the
codex adapter) rather than repeating the raw CLI error text.
"""
import importlib
import subprocess
import time

# No infinite path: every invoke_cli() call gets a timeout, even a caller
# that forgets to pass one explicitly.
DEFAULT_TIMEOUT_SECONDS = 60


class AdapterError(Exception):
    """Base class for every error a `complete()` call may raise (Sec8.5)."""


class Timeout(AdapterError):
    """The provider CLI did not exit within the mandatory timeout."""


class NonzeroExit(AdapterError):
    """The provider CLI exited nonzero for a reason other than auth."""


class UnparseableOutput(AdapterError):
    """The provider CLI's stdout could not be parsed into a completion."""


class AuthExpired(AdapterError):
    """The provider CLI's exit/output indicates the stored credential is
    missing or expired. Message always instructs the login command."""


def invoke_cli(argv, *, timeout=DEFAULT_TIMEOUT_SECONDS, env=None, cwd=None):
    """Runs one provider-CLI turn. `argv` MUST be a list/tuple (never a
    shell string -- Sec17.3): every element travels to the OS as one literal
    argument, so an injection attempt inside a context message can never be
    reinterpreted by a shell (there is no shell in the invocation path).

    Returns a `subprocess.CompletedProcess` (returncode/stdout/stderr) on
    any exit, or raises `Timeout` if the process outlives `timeout`. Never
    raises for a nonzero exit -- classifying that (NonzeroExit vs
    AuthExpired) is the calling adapter's job, since only it knows its own
    CLI's auth-failure signature.
    """
    if not isinstance(argv, (list, tuple)):
        raise TypeError(
            "invoke_cli requires argv as a list/tuple, never a shell string "
            "(SPEC-ASSISTANT.md Sec17.3)"
        )
    start = time.monotonic()
    try:
        return subprocess.run(
            list(argv),
            capture_output=True,
            text=True,
            timeout=timeout,
            stdin=subprocess.DEVNULL,
            env=env,
            cwd=cwd,
            shell=False,
        )
    except subprocess.TimeoutExpired as exc:
        elapsed = time.monotonic() - start
        raise Timeout(
            f"provider CLI '{argv[0]}' did not complete within {timeout}s "
            f"(killed after {elapsed:.1f}s)"
        ) from exc


# provider name -> registered complete(context, **kwargs) callable. Adapter
# modules register themselves at import time (see the bottom of codex.py).
_REGISTRY = {}

# provider name -> dotted module that registers it, imported lazily by
# get_adapter() below rather than eagerly here -- importing adapters.py
# alone never imports a provider module and never spawns a subprocess
# (Sec17.1's isolation rule extends to import time, not just call time).
# "claude" (AST-012) is a deliberate seam: it is not listed here, so asking
# for it falls straight through to the KeyError below.
_PROVIDER_MODULES = {
    "codex": "assistant.codex",
    "openai": "assistant.codex",
}


def register_adapter(provider, complete_fn):
    """Registers `complete_fn` under `provider`'s name. Called once per
    adapter module at import time."""
    _REGISTRY[provider] = complete_fn


def get_adapter(provider):
    """Returns the registered `complete(context, **kwargs)` callable for
    `provider` (e.g. "openai", per config.py's PROVIDER_CAPABILITY mapping
    -- the `llm.provider` value from a repo's `assistant:` section).
    Lazily imports the provider's adapter module on first use (so callers
    never have to remember `import assistant.codex` themselves) and raises
    KeyError naming the known providers for an unknown or not-yet-
    implemented one: "claude" (AST-012) is a deliberate seam -- it is not
    in `_PROVIDER_MODULES`, so asking for it fails the same way an unknown
    provider would, with no special-cased message to keep in sync."""
    if provider not in _REGISTRY and provider in _PROVIDER_MODULES:
        importlib.import_module(_PROVIDER_MODULES[provider])
    try:
        return _REGISTRY[provider]
    except KeyError:
        known = ", ".join(sorted(_PROVIDER_MODULES)) or "(none registered)"
        raise KeyError(
            f"no adapter registered for provider {provider!r} (known: {known})"
        ) from None
