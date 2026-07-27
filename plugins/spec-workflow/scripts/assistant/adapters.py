"""Provider adapter contract (SPEC-ASSISTANT.md Sec5a, Sec8.1, Sec8.4, Sec8.5,
Sec17.1-Sec17.3).

AST-011/AST-012 fill in the contract AST-010 stubbed: `complete(context) ->
{text, usage, timings}`, one stateless provider-CLI invocation per turn
(Sec8.1). Every adapter (codex.py, claude.py) funnels its
subprocess call through `invoke_cli()` below so the argv-array-only
(Sec17.3), mandatory-timeout (Sec8.5), and structured-error (Sec8.5)
invariants are enforced in exactly one place instead of per-adapter.

Error taxonomy (Sec8.5): the provider CLI exiting nonzero, timing out,
never even starting (binary missing/unexecutable -- issue #408), or
emitting output the adapter cannot parse SHALL surface a bounded-time,
specific error -- never a bare stack trace or an indefinite hang. An
auth-expired state instructs the login command (`codex login` for the
codex adapter) rather than repeating the raw CLI error text.

AST-063 (SPEC-ASSISTANT.md Sec11.5, Sec17.3, issue #338, docs/design/ast-E6.md)
adds `invoke_argv`: a capability's `invoke.exec` argv-array invocation, with
its declared parameters schema-validated BEFORE any placeholder
substitution or subprocess spawn. This reuses `invoke_cli` for the actual
spawn (design doc: "provisioning checks and invoke both go through
adapters.py's existing sandboxed-subprocess path") -- no invoke path gets
its own, second way to reach a shell or an unbounded subprocess.

capability.yaml's `invoke.exec` is an argv-array template (Sec11.5);
`invoke.params` (this task's addition -- see the interpretation note below)
is an OPTIONAL mapping `{paramName: {type, pattern?, allowlist?,
required?}}` declaring the schema those templated params must satisfy.
`type` is one of "string"/"int"/"number"/"bool"; `pattern` (string type
only) is a regex checked with `re.fullmatch`; `allowlist` is a list of
exact-match allowed values, checked after type; `required` defaults to
`True`. A param not declared in the schema is itself a validation error
(§17.3's argv-array invariant only makes sense for FULLY-declared params --
an ad hoc, undeclared param would be exactly the kind of untyped, untrusted
string this task exists to keep out of the invoke path).

Interpretation note (flagged per house lesson
acceptance-criterion-outranks-test-spec-paraphrase): capability_index.py's
landed capability.yaml schema (AST-060, `_check_invoke`) validates only
`invoke.exec`/`invoke.mcp` and does not mention a `params` key; it also
does not reject unknown keys inside `invoke`, so adding `invoke.params`
here is additive and does not change AST-060's validation behavior for any
existing capability.yaml. §11.5 requires "schema-validated parameters" but
neither §11 nor docs/design/ast-E6.md's Data Models section names where
that schema lives -- `invoke.params` is this task's concrete answer, kept
entirely inside adapters.py (never touching capability_index.py's frozen
AST-060 structural validation) so this stays a same-lane, additive change.
"""
import collections
import importlib
import re
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


class NotFound(AdapterError):
    """The provider CLI binary itself could not be located or executed --
    FileNotFoundError/PermissionError/NotADirectoryError from the OS at
    Popen time (e.g. the CLI is not installed, or a stale/bogus path was
    configured). Distinct from NonzeroExit: the CLI process never even
    started, so there is no exit code or output to report (issue #408 --
    this divergence between a dev machine with the CLI installed and a
    CI runner without it must surface as a clean AdapterError, never an
    escaping OSError traceback)."""


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
    except OSError as exc:
        # Popen itself failed -- the binary named in argv[0] does not
        # exist, is not executable, or a directory component is bogus
        # (issue #408: a dev machine with the real CLI on PATH never hits
        # this, so it must be exercised deliberately -- see
        # section-assistant-adapter.sh's "missing binary" case). Wrapped
        # into an AdapterError so every caller's `except adapters.
        # AdapterError` (e.g. engine._chat) already handles it cleanly,
        # matching Sec8.5's "never a bare stack trace" invariant.
        raise NotFound(
            f"provider CLI '{argv[0]}' could not be executed: {exc}"
        ) from exc


# provider name -> registered complete(context, **kwargs) callable. Adapter
# modules register themselves at import time (see the bottom of codex.py).
_REGISTRY = {}

# provider name -> dotted module that registers it, imported lazily by
# get_adapter() below rather than eagerly here -- importing adapters.py
# alone never imports a provider module and never spawns a subprocess
# (Sec17.1's isolation rule extends to import time, not just call time).
_PROVIDER_MODULES = {
    "codex": "assistant.codex",
    "openai": "assistant.codex",
    "claude": "assistant.claude",
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
    never have to remember `import assistant.codex`/`assistant.claude`
    themselves) and raises KeyError naming the known providers for any
    provider not in `_PROVIDER_MODULES`, with no special-cased message to
    keep in sync."""
    if provider not in _REGISTRY and provider in _PROVIDER_MODULES:
        importlib.import_module(_PROVIDER_MODULES[provider])
    try:
        return _REGISTRY[provider]
    except KeyError:
        known = ", ".join(sorted(_PROVIDER_MODULES)) or "(none registered)"
        raise KeyError(
            f"no adapter registered for provider {provider!r} (known: {known})"
        ) from None


# ------------------------------------------------------------------------
# AST-063 (Sec11.5, Sec17.3): argv-array invoke with schema-validated params.
# ------------------------------------------------------------------------

InvokeResult = collections.namedtuple("InvokeResult", ["argv", "returncode", "stdout", "stderr"])

# type name -> predicate(value) -> bool. bool is checked BEFORE int/number
# in every branch below (house lesson bool-before-int-guard:
# `isinstance(True, int)` is `True`, so a naive `isinstance(value, int)`
# check would silently accept a bool as a valid "int"/"number" param).
_PARAM_TYPE_CHECKS = {
    "string": lambda v: isinstance(v, str),
    "bool": lambda v: isinstance(v, bool),
    "int": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
}

_PLACEHOLDER_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")


class ParamValidationError(AdapterError):
    """One or more `invoke.params`-declared constraints (type/pattern/
    allowlist/required/undeclared) were violated. `.errors` is the full
    list of specific, per-param messages (see `validate_params`); the
    exception's own message joins them so a bare `str(exc)` already reads
    as a complete, specific report -- callers that want to inspect
    individual violations use `.errors` directly."""

    def __init__(self, errors):
        self.errors = list(errors)
        super().__init__("; ".join(self.errors))


def _type_error(name, expected_type, value):
    return (
        f"param {name!r}: type mismatch: expected {expected_type!r}, "
        f"got {type(value).__name__} (value={value!r})"
    )


def _validate_one_param(name, spec, value, errs):
    if not isinstance(spec, dict):
        errs.append(f"param {name!r}: schema entry must be a mapping (got {type(spec).__name__})")
        return

    expected_type = spec.get("type")
    check = _PARAM_TYPE_CHECKS.get(expected_type)
    if check is None:
        errs.append(
            f"param {name!r}: schema declares unknown type {expected_type!r} "
            f"(known: {sorted(_PARAM_TYPE_CHECKS)})"
        )
        return
    if not check(value):
        errs.append(_type_error(name, expected_type, value))
        return  # a value that fails its type check is never further validated

    pattern = spec.get("pattern")
    if pattern is not None:
        if expected_type != "string":
            errs.append(f"param {name!r}: schema error: 'pattern' is only valid for type 'string'")
        else:
            try:
                matched = re.fullmatch(pattern, value) is not None
            except re.error as exc:
                # A malformed regex in the schema itself (e.g. an unclosed
                # character class) is a capability-authoring bug, not a
                # caller-supplied-value problem -- surface it the same
                # specific way, never a raw re.error escaping into the
                # AdapterError taxonomy's caller.
                errs.append(f"param {name!r}: schema error: invalid pattern {pattern!r}: {exc}")
            else:
                if not matched:
                    errs.append(
                        f"param {name!r}: pattern mismatch: value {value!r} does not match pattern {pattern!r}"
                    )

    allowlist = spec.get("allowlist")
    if allowlist is not None:
        if value not in allowlist:
            errs.append(
                f"param {name!r}: not in allowlist {list(allowlist)!r}: got {value!r}"
            )


def validate_params(param_schema, params):
    """Validates `params` (a `{name: value}` mapping) against
    `param_schema` (a `{name: {type, pattern?, allowlist?, required?}}`
    mapping, `invoke.params` -- see module docstring). Returns a list of
    specific, human-readable error strings; an empty list means every
    declared param is present-and-valid and every supplied param is
    declared -- never raises, matches this module's/`capability_index.
    validate_capability`'s check/record/continue style so a caller can
    report every violation at once instead of just the first.

    Each error names the offending param, the constraint kind (missing/
    type/pattern/allowlist/not declared), and the offending value's shape
    -- Sec11.5's "schema-validated parameters" only means something if a
    validation failure is actionable, not a bare boolean."""
    errs = []
    schema = param_schema if isinstance(param_schema, dict) else {}
    params = params if isinstance(params, dict) else {}

    for name, spec in schema.items():
        required = True
        if isinstance(spec, dict) and "required" in spec:
            required = bool(spec["required"])
        if name not in params:
            if required:
                errs.append(f"param {name!r}: missing required param")
            continue
        _validate_one_param(name, spec, params[name], errs)

    for name in params:
        if name not in schema:
            errs.append(f"param {name!r}: not declared in capability's param schema")

    return errs


def substitute_argv(exec_argv, params):
    """Substitutes `{paramName}` placeholders into `exec_argv` (Sec11.5:
    "placeholder substitution occurs only within single argv elements").
    Each templated argv element is a single string that may contain one or
    more `{name}` placeholders -- every placeholder in that element is
    replaced with `str(params[name])` IN PLACE, so N placeholders inside
    one element still produce exactly ONE resulting argv element (never
    split into several, never merged across elements). Elements with no
    placeholder at all pass through unchanged.

    Called only after `invoke_argv` has already confirmed (via
    `validate_params` AND its own placeholder-coverage check) that every
    referenced placeholder has a matching entry in `params` -- so the
    `KeyError` this raises for an unresolved placeholder should never
    actually surface through `invoke_argv` itself; it remains a defensive
    guard for any OTHER caller of this function directly."""
    substituted = []
    for element in exec_argv:
        def _sub(match, _params=params):
            key = match.group(1)
            if key not in _params:
                raise KeyError(f"invoke.exec placeholder {{{key}}} has no matching param")
            return str(_params[key])

        substituted.append(_PLACEHOLDER_RE.sub(_sub, element))
    return substituted


def _extract_placeholders(exec_argv):
    """Every distinct `{name}` placeholder referenced anywhere in
    `exec_argv`, in first-seen order. Assumes every element is already a
    string -- `invoke_argv` validates that structurally before calling
    this."""
    seen = []
    for element in exec_argv:
        for name in _PLACEHOLDER_RE.findall(element):
            if name not in seen:
                seen.append(name)
    return seen


def _capability_invoke(capability):
    invoke = getattr(capability, "invoke", None)
    if invoke is None and isinstance(capability, dict):
        invoke = capability.get("invoke")
    return invoke if isinstance(invoke, dict) else {}


def invoke_argv(capability, params, *, timeout=DEFAULT_TIMEOUT_SECONDS, env=None, cwd=None):
    """Runs `capability`'s `invoke.exec` as an argv array (Sec11.5,
    Sec17.3): validates `params` against `invoke.params` (see
    `validate_params`) BEFORE any substitution or subprocess spawn --
    an invalid call raises `ParamValidationError` and never touches
    `invoke_cli`, so a rejected capability invocation is guaranteed to
    never run anything. Once params validate, `substitute_argv` builds the
    final literal argv array and `invoke_cli` runs it (`shell=False`,
    mandatory timeout -- the SAME primitive every provider adapter and
    `provisioning.run_check` already funnel through, per docs/design/
    ast-E6.md's "provisioning checks and invoke both go through adapters.py's
    existing sandboxed-subprocess path").

    Returns `InvokeResult(argv, returncode, stdout, stderr)` on any exit;
    raises `ParamValidationError` for EVERY invalid-input class this
    function can detect ahead of spawning anything -- a malformed
    `invoke.exec` (non-argv-array, or a non-string element -- mirrors
    `capability_index._check_argv`'s structural check), a schema violation
    (`validate_params`: missing/type/pattern/allowlist/undeclared,
    including a malformed regex `pattern` itself), or a placeholder in
    `invoke.exec` that names a param never supplied (the `required: false`
    case: a legitimate, schema-valid capability.yaml can still reference an
    optional param's placeholder without the caller ever supplying it --
    `invoke.exec` has no default-value syntax, so that is a template/call
    mismatch, not a crash). Only `invoke_cli`'s own `AdapterError`
    subclasses (`Timeout`, `NotFound`) -- genuine spawn-time failures --
    escape this function as anything other than `ParamValidationError`;
    never a bare stack trace, matching Sec8.5's error taxonomy for the
    sibling provider-adapter invocation path."""
    invoke = _capability_invoke(capability)
    exec_argv = invoke.get("exec")
    if not isinstance(exec_argv, list) or not exec_argv:
        raise ParamValidationError([
            "invoke.exec must be a non-empty argv array (SPEC-ASSISTANT.md Sec11.5)"
        ])
    element_errs = [
        f"invoke.exec[{i}]: must be a string (got {type(element).__name__})"
        for i, element in enumerate(exec_argv)
        if not isinstance(element, str)
    ]
    if element_errs:
        # Can't safely scan for placeholders (str.findall) with a
        # non-string element present -- report and stop here rather than
        # risk a second, unrelated TypeError.
        raise ParamValidationError(element_errs)

    param_schema = invoke.get("params")
    errs = validate_params(param_schema, params)

    supplied = params if isinstance(params, dict) else {}
    for name in _extract_placeholders(exec_argv):
        if name not in supplied:
            errs.append(
                f"invoke.exec references placeholder {{{name}}} but no value was supplied for "
                f"param {name!r} (declare it required, or always supply a value -- invoke.exec "
                "has no default-value syntax)"
            )
    if errs:
        raise ParamValidationError(errs)

    argv = substitute_argv(exec_argv, supplied)
    result = invoke_cli(argv, timeout=timeout, env=env, cwd=cwd)
    return InvokeResult(argv=argv, returncode=result.returncode, stdout=result.stdout, stderr=result.stderr)
