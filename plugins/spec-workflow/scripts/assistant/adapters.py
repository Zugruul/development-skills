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

AST-064 (SPEC-ASSISTANT.md Sec11.7, issue #339, docs/design/ast-E6.md)
adds `invoke_mcp`: MCP servers are the OTHER invoke flavor (`invoke: {mcp:
...}`, sibling to AST-063's `invoke: {exec: ...}`). `invoke.mcp` is this
task's concrete schema (same interpretation-note posture as
`invoke.params` above -- capability_index.py's AST-060 validation only
checks `isinstance(invoke["mcp"], dict)` and names nothing further, so this
is additive, adapters.py-only): `{server: argv-array, tool: string,
params?: same schema shape as invoke.params}`. `invoke_mcp` spawns
`server` via the SAME `invoke_cli` primitive `invoke_argv` uses
(`shell=False`, mandatory timeout -- no second subprocess mechanism),
writes ONE JSON-RPC 2.0 `tools/call` request to its stdin, and reads ONE
JSON-RPC response from its stdout before the process exits -- a single
round trip per call, never a persistent, multi-call server session (a real
MCP client's `initialize`/`initialized` handshake and long-lived stdio
session are out of scope for this task's "one round-trip invocation
fixture" acceptance criterion; a future task can grow a persistent-session
flavor on top of this one without changing `invoke_mcp`'s public shape).
Params reuse `validate_params` verbatim -- no forked validation logic --
and are sent as the JSON-RPC request's structured `arguments` object
(never argv-templated: unlike `invoke.exec`, `invoke.mcp.server` is a
FIXED launch argv with no placeholders, since params travel as JSON data,
not as shell-adjacent string substitution).
"""
import collections
import importlib
import json
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


def invoke_cli(argv, *, timeout=DEFAULT_TIMEOUT_SECONDS, env=None, cwd=None, input=None):
    """Runs one provider-CLI turn. `argv` MUST be a list/tuple (never a
    shell string -- Sec17.3): every element travels to the OS as one literal
    argument, so an injection attempt inside a context message can never be
    reinterpreted by a shell (there is no shell in the invocation path).

    `input` (AST-064, issue #339) is optional text written to the child's
    stdin before it's closed -- `None` (the default, every pre-existing
    caller) preserves the original `stdin=DEVNULL` behavior exactly;
    `invoke_mcp` is the first caller to pass one, for its single JSON-RPC
    request. Still exactly one subprocess primitive for every invoke path
    (provider adapters, `provisioning.run_check`, `invoke_argv`,
    `invoke_mcp`) -- `shell=False` and the mandatory `timeout` apply
    identically regardless of `input`.

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
    run_kwargs = dict(capture_output=True, text=True, timeout=timeout, env=env, cwd=cwd, shell=False)
    if input is None:
        run_kwargs["stdin"] = subprocess.DEVNULL
    else:
        run_kwargs["input"] = input
    try:
        return subprocess.run(list(argv), **run_kwargs)
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
    validation failure is actionable, not a bare boolean.

    Two declaration-shape checks run FIRST and short-circuit the rest
    (issue #339 round 2 MINORs 3/4 -- shared by both invoke flavors,
    `invoke_argv`'s `invoke.params` AND `invoke_mcp`'s `invoke.mcp.params`,
    since both funnel through this one function):
      - `param_schema` itself must be `None` (no schema declared) or a
        mapping. A capability-authoring typo like `params: ["city"]` (a
        list, not a mapping) used to silently coerce to `{}`, which then
        misreported every supplied param as "not declared" -- pointing the
        blame at the CALLER for what is actually a malformed SCHEMA.
      - `params` (the caller-supplied values) itself must be `None` (no
        params supplied) or a mapping. A non-mapping `params` argument
        (e.g. a list) used to silently coerce to `{}` and the call would
        proceed as if no params were supplied at all -- closing that
        silent-success gap here covers both `invoke_argv` and
        `invoke_mcp`."""
    errs = []
    if param_schema is not None and not isinstance(param_schema, dict):
        errs.append(f"params schema: must be a mapping (got {type(param_schema).__name__})")
    if params is not None and not isinstance(params, dict):
        errs.append(f"params: must be a mapping (got {type(params).__name__})")
    if errs:
        return errs

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


# ------------------------------------------------------------------------
# AST-064 (Sec11.7): MCP invoke flavor -- one JSON-RPC round trip per call.
# ------------------------------------------------------------------------

McpInvokeResult = collections.namedtuple(
    "McpInvokeResult", ["argv", "request", "response", "result", "returncode", "stdout", "stderr"]
)


class McpError(AdapterError):
    """Base class for round-trip-level MCP invocation failures (Sec11.7) --
    distinct from `ParamValidationError` (a bad `invoke.mcp` declaration or
    a bad params value, caught before anything spawns) and from
    `invoke_cli`'s own `Timeout`/`NotFound` (spawn-time failures, reused
    as-is -- an MCP server IS just another subprocess `invoke_cli` runs)."""


class McpUnparseableOutput(McpError):
    """The MCP server's stdout could not be parsed as a single, well-formed
    JSON-RPC 2.0 response for THIS call: not valid JSON, not a JSON object,
    missing/duplicating the mutually-exclusive `result`/`error` pair
    (JSON-RPC 2.0 requires exactly one), or carrying an `id` that does not
    match the request's `id` (this is a one-shot, one-round-trip call --
    a mismatched id means the reply cannot be trusted to be THIS call's
    reply). Never a raw `json.JSONDecodeError`/`KeyError` escaping to the
    caller."""


class McpToolError(McpError):
    """The MCP server accepted the round trip (valid JSON-RPC, matching
    id) but its response carries an `error` object -- the tool call itself
    failed server-side. Message names the tool, the JSON-RPC error code,
    and the error message, never just the raw response dict."""


def _parse_mcp_response(stdout, expected_id):
    """Scans `stdout` line by line for the first line that parses as a JSON
    object whose `id` matches `expected_id` (issue #339 round 2 MINOR 1).
    A real stdio MCP server may emit notifications (JSON-RPC objects with
    no `id`) or plain log/banner lines before the actual `tools/call`
    reply -- `json.loads(entire stdout)` breaks on either shape. This is
    what a real stdio client does: read line by line, ignore anything that
    doesn't parse as JSON or doesn't carry OUR request's `id`, and treat
    the first id-matching object as THIS call's reply (correlating by id
    is also what makes this scanning approach a safe, extensible seam for
    a future persistent-session flavor -- multiple in-flight ids on one
    connection would resolve the same way).

    Returns that object, or `None` if no line matches (either truly
    unparseable stdout, or a reply whose id never matches -- both read as
    "no usable reply for this call" to the caller, which raises
    `McpUnparseableOutput` with a message naming the expected id)."""
    for line in (stdout or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            candidate = json.loads(line)
        except (json.JSONDecodeError, ValueError):
            continue
        if isinstance(candidate, dict) and candidate.get("id") == expected_id:
            return candidate
    return None


def _validate_mcp_declaration(mcp, errs):
    server = mcp.get("server")
    if not isinstance(server, list) or not server or not all(isinstance(a, str) for a in server):
        errs.append(
            "invoke.mcp.server: must be a non-empty argv array of strings "
            "(SPEC-ASSISTANT.md Sec11.7/Sec17.3)"
        )
    tool = mcp.get("tool")
    if not isinstance(tool, str) or not tool:
        errs.append("invoke.mcp.tool: must be a non-empty string naming the MCP tool to call")


def invoke_mcp(capability, params, *, timeout=DEFAULT_TIMEOUT_SECONDS, env=None, cwd=None):
    """Runs ONE JSON-RPC 2.0 `tools/call` round trip against `capability`'s
    `invoke.mcp` server (Sec11.7): validates the `invoke.mcp` DECLARATION
    itself (`server`/`tool` shape -- a malformed capability.yaml, never a
    caller-supplied-value problem) and `params` against `invoke.mcp.params`
    (via `validate_params` -- the SAME schema/validation machinery
    `invoke_argv` uses, not a forked implementation) BEFORE spawning
    anything; an invalid call raises `ParamValidationError` and never
    touches `invoke_cli`, exactly like `invoke_argv`.

    Once valid, spawns `invoke.mcp.server` through `invoke_cli` (`shell=
    False`, mandatory timeout -- the SAME primitive `invoke_argv`/
    `provisioning.run_check`/every provider adapter already funnels
    through), writing one `{"jsonrpc":"2.0","id":1,"method":"tools/call",
    "params":{"name":<tool>,"arguments":<params>}}` request to its stdin
    and reading its stdout after it exits -- a single round trip, never a
    persistent session (see module docstring). The reply is located via
    `_parse_mcp_response` (line-by-line, id-correlated -- tolerates
    notification/log-line noise before the actual reply, issue #339 round
    2 MINOR 1).

    Response classification is PARSE-BEFORE-RETURNCODE (issue #339 round 2
    MINOR 2): a well-formed, id-matching JSON-RPC ERROR reply is
    authoritative even if the server ALSO happened to exit nonzero -- the
    richer `McpToolError` (tool name, JSON-RPC code, JSON-RPC message)
    beats a bare `NonzeroExit` whose stderr tail would otherwise be empty
    (the actual detail lived in stdout, not stderr). Only once that check
    finds nothing does a nonzero exit get treated as authoritative.

    Returns `McpInvokeResult(argv, request, response, result, returncode,
    stdout, stderr)` on a genuinely successful round trip (`result` is the
    JSON-RPC response's `result` field, already extracted for
    convenience). Raises, all inside the `AdapterError` taxonomy, never a
    bare stack trace:
      - `ParamValidationError` -- malformed `invoke.mcp` declaration, or a
        params violation (missing/type/pattern/allowlist/undeclared/
        non-mapping schema or params).
      - `invoke_cli`'s own `Timeout`/`NotFound` -- spawn-time failures.
      - `McpToolError` -- a well-formed, id-matching reply carries an
        `error` object -- the tool call itself failed (checked BEFORE
        returncode, see above).
      - `NonzeroExit` -- the server process exited nonzero and no
        id-matching error reply was found.
      - `McpUnparseableOutput` -- no line of stdout parsed as a single,
        well-formed, id-matching JSON-RPC response (the server exited 0
        but never sent a usable reply)."""
    invoke = _capability_invoke(capability)
    mcp = invoke.get("mcp")
    mcp = mcp if isinstance(mcp, dict) else {}

    decl_errs = []
    _validate_mcp_declaration(mcp, decl_errs)
    if decl_errs:
        raise ParamValidationError(decl_errs)

    param_schema = mcp.get("params")
    param_errs = validate_params(param_schema, params)
    if param_errs:
        raise ParamValidationError(param_errs)

    server_argv = list(mcp["server"])
    tool = mcp["tool"]
    supplied = params if isinstance(params, dict) else {}

    request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {"name": tool, "arguments": supplied},
    }
    result = invoke_cli(server_argv, timeout=timeout, env=env, cwd=cwd, input=json.dumps(request) + "\n")

    response = _parse_mcp_response(result.stdout, request["id"])
    has_result = has_error = False
    if response is not None:
        has_result = "result" in response
        has_error = "error" in response

    # Parse-before-returncode (MINOR 2): a well-formed, id-matching ERROR
    # reply wins even over a nonzero exit -- checked first, before the
    # returncode gate below.
    if response is not None and has_error and not has_result:
        err = response["error"]
        code = err.get("code") if isinstance(err, dict) else None
        message = err.get("message") if isinstance(err, dict) else str(err)
        raise McpToolError(
            f"MCP server {server_argv[0]!r} tool {tool!r} returned an error (code={code}): {message}"
        )

    if result.returncode != 0:
        stderr_tail = (result.stderr or "").strip()[-240:]
        raise NonzeroExit(
            f"MCP server {server_argv[0]!r} exited {result.returncode} calling tool {tool!r}"
            + (f": {stderr_tail}" if stderr_tail else "")
        )

    if response is None:
        raise McpUnparseableOutput(
            f"MCP server {server_argv[0]!r} tool {tool!r}: no line of stdout parsed as a JSON-RPC "
            f"response object with id={request['id']!r} matching this call"
        )

    if has_result == has_error:
        raise McpUnparseableOutput(
            f"MCP server {server_argv[0]!r} tool {tool!r}: JSON-RPC 2.0 response (id={request['id']!r}) "
            f"must carry exactly one of 'result'/'error', got has_result={has_result} has_error={has_error}"
        )

    # has_result True, has_error False, returncode == 0 here -- genuine success.
    return McpInvokeResult(
        argv=server_argv,
        request=request,
        response=response,
        result=response["result"],
        returncode=result.returncode,
        stdout=result.stdout,
        stderr=result.stderr,
    )
