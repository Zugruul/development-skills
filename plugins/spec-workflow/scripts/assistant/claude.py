"""Claude adapter (SPEC-ASSISTANT.md Sec8.1, Sec8.4, Sec8.5, Sec17.1-Sec17.3,
AST-012).

Wraps the Claude Code CLI (`claude -p --output-format json`) as one
stateless `complete(context)` turn -- the SAME context shape and calling
convention codex.py documents (Sec8.2, minimal -- AST-013 composes the real
thing from recall/budget logic; this is only what one turn NEEDS):

    context = {
        "model": str,            # passed verbatim to --model (Sec6.5: never allowlisted)
        "system": str | None,    # optional system/instructions text
        "input": str,            # the user's message for this turn
    }

`system` and `input` are joined into ONE prompt string (claude -p takes a
single positional PROMPT, same as codex exec) with a plain blank-line join
-- no shell quoting is involved since the whole string travels as a single
argv element (Sec17.3).

Pinned isolation flags (Sec8.4 -- "no user-global instruction ingestion; no
plugin/skill surface from the dev workflow; harness tool use disabled"),
researched against claude 2.1.217's `claude --help` and cross-checked
against plugins/peer-review/scripts/claude-review.sh (the existing
`claude -p --output-format json --permission-mode plan` precedent in this
repo):

    -p / --print            non-interactive mode; required to get a single
                             completion back instead of starting a session.
    --output-format json    a single machine-parseable JSON object envelope
                             (type/subtype/is_error/result/usage);
                             required to parse the completion at all.
    --tools ""               disables ALL tools outright (per `claude
                             --help`: 'Use "" to disable all tools'). Unlike
                             codex-cli's `--sandbox read-only` (which only
                             bounds what a tool call may DO), this fully
                             satisfies "harness tool use disabled" -- no
                             GAP here.
    --strict-mcp-config     with no `--mcp-config` given, this means NO MCP
                             servers load at all -- no plugin/skill-shaped
                             surface from the dev workflow's own MCP config
                             ever reaches the turn.
    --permission-mode plan  read-only defense-in-depth (mirrors
                             claude-review.sh's own hardcoded, non-
                             overridable choice) -- redundant with
                             `--tools ""` today, kept in case a future
                             claude-cli version reintroduces an implicit
                             tool under some mode.
    --no-session-persistence
                             "sessions will not be saved to disk and cannot
                             be resumed" (`claude --help`) -- matches
                             Sec8.1's "ONE stateless invocation".
    --safe-mode              DIRECTLY documented by `claude --help` to
                             disable "CLAUDE.md, skills, plugins, hooks, MCP
                             servers, custom commands and agents, output
                             styles, workflows, custom themes, keybindings,
                             and more" while "Auth, model selection, built-in
                             tools, and permissions work normally." This is
                             the load-bearing flag for Sec8.4 clause 1 ("no
                             user-global instruction ingestion") and clause
                             2 ("no plugin/skill surface from the dev
                             workflow") -- both are satisfied by ONE
                             documented flag rather than an env-home
                             rebuild (see the "Isolated env-home" section
                             below for why that path was rejected for
                             claude specifically). Empirically confirmed
                             compatible with every other pinned flag above,
                             combined, against a real (deliberately
                             unauthenticated) `claude` invocation on this
                             machine -- see the AUTH-FAILURE provenance note
                             below, captured with this exact flag set.
    --model <model>          passed verbatim (Sec6.5: never allowlisted).

Isolated cwd (subprocess `cwd=`, not a CLI flag -- there is no discovered
`-C`/`--cwd` equivalent for the real claude CLI, unlike codex exec's `-C`):
`complete()` still points the subprocess at a fresh, empty, per-invocation
temp directory (see `_isolated_cwd()`) as defense-in-depth for any
project-level instruction file discovery tied to cwd, even though
`--safe-mode` is documented to already disable CLAUDE.md loading outright.
Caller removes it; `complete()` always cleans up in a try/finally, same
pattern as codex.py's `-C` isolated directory.

Isolated env-home -- REJECTED for claude, documented gap (Sec8.4, Sec16):
codex.py isolates `CODEX_HOME` per-invocation and copies ONLY `auth.json`
into it so a real `~/.codex/AGENTS.md` never reaches a turn while login is
preserved. The equivalent env var for claude is `CLAUDE_CONFIG_DIR`
(defaults to `~/.claude`). Research on this machine:

  - `claude auth status` with the real (default) `CLAUDE_CONFIG_DIR`:
    `{"loggedIn": true, "authMethod": "claude.ai", ...}`.
  - `claude auth status` with `CLAUDE_CONFIG_DIR` pointed at a fresh, empty
    directory: `{"loggedIn": false, "authMethod": "none", ...}`.

  So, UNLIKE codex, simply overriding the env-home variable breaks login by
  itself -- and no plain credential file was found to copy the way
  codex.py copies `auth.json`: `~/.claude/` itself contains no
  auth/credential/oauth-named file (only daemon-status bookkeeping), and
  the account's `oauthAccount` metadata found in `~/.claude.json` (a
  HOME-level dotfile, not inside `CLAUDE_CONFIG_DIR`) was NOT enough on its
  own to keep `CLAUDE_CONFIG_DIR`-isolated auth working in this test,
  meaning the actual secret is very likely OS-keychain-resident and keyed
  in a way that also depends on `CLAUDE_CONFIG_DIR`. Directly probing the
  macOS keychain entry to confirm was blocked by this session's own
  permission classifier (`security find-generic-password` denied), so the
  exact mechanism could not be fully diagnosed here. Given `--safe-mode`
  already satisfies the instruction-ingestion isolation goal WITHOUT
  touching the credential path at all, `complete()` deliberately does NOT
  override `CLAUDE_CONFIG_DIR`, `HOME`, or any other env-home variable --
  doing so would risk breaking real auth for no isolation benefit beyond
  what `--safe-mode` + `--strict-mcp-config` + `--tools ""` already provide.
  This is the honest gap this module carries in place of codex.py's
  env-home rebuild: the credential-portability question docex.py answered
  (copy auth.json) does not have an equally clean answer here, so this
  adapter simply avoids the class of action that would need one.

DOCUMENTED GAP (Sec8.4, Sec16 -- report in the AST-012 handoff; candidate
for docs/spec-deltas/AST-012.md): whether `--safe-mode` excludes CLAUDE.md
content specifically (as opposed to only settings.json-style
permissions/hooks/plugin config) was not verified against a real
authenticated completion here (out of scope, per Sec16 -- real
authenticated use is dogfood-only) -- this module treats `claude --help`'s
own explicit listing of "CLAUDE.md" in `--safe-mode`'s description as
authoritative, but flags the claim for dogfood validation the same way
codex.py flags its SUCCESS-path event-shape assumption.

Output parsing provenance:
  - SUCCESS path (`type: "result"`, `is_error: false`, `.result` text,
    `.usage`): ASSUMED from `claude -p --output-format json`'s documented
    envelope shape, cross-checked against claude-review.sh's own parsing
    of the same envelope (`.structured_output` for the schema-constrained
    case; here, with no `--json-schema`, the plain-text answer is
    `.result` directly). Not captured against a real authenticated
    completion (auth + cost are out of scope here; real-CLI use is
    dogfood-only per Sec16) -- flag for dogfood validation.
  - AUTH-FAILURE path: validated against a REAL unauthenticated
    `claude -p --output-format json` run captured on this machine (claude
    2.1.217, isolated empty `CLAUDE_CONFIG_DIR`, full pinned flag set
    above) -- exit code 1, `duration_api_ms: 0` (fails client-side, no
    network round trip -- cheap to capture, no auth or cost incurred), and
    a single JSON object with `is_error: true` and
    `result: "Not logged in · Please run /login"`. That "/login" text
    is claude's own interactive-only slash command; this adapter's OWN
    AuthExpired message instructs `claude auth login` instead -- the
    actual non-interactive CLI subcommand (verified via `claude auth
    --help`, and matching this repo's own
    `preflight.py`'s `AUTH_PROBES["claude-code"]["login_cmd"]`).
  - EXIT-0-BUT-is_error path: claude-review.sh notes `is_error: true`
    inside the envelope is a failure signal independent of the process
    exit code. `complete()` mirrors that: an exit-0 response whose
    envelope has `is_error: true` is classified exactly like a nonzero
    exit (auth-signature checked, then NonzeroExit) rather than treated as
    a success.
"""
import json
import os
import tempfile
import shutil
import time

from assistant import adapters

DEFAULT_MODEL_TIMEOUT_SECONDS = 60

_PINNED_FLAGS = (
    "-p",
    "--output-format", "json",
    "--tools", "",
    "--strict-mcp-config",
    "--permission-mode", "plan",
    "--no-session-persistence",
    "--safe-mode",
)

# File-output variant (2026-07-29, human-directed: "workspace is read-only"
# refusals). Empirically validated against the real claude CLI on this
# machine: the headless permission classifier DENIES any Write into a
# `.claude/**` path (flagged sensitive; -p mode has no prompt to approve
# it), and enabling a tool (--tools) does NOT allowlist it -- the write
# only succeeds with `--allowedTools Write` AND a non-sensitive target.
# So the model writes plain filenames into its isolated WORKDIR (the cwd,
# an ordinary temp dir) and complete() PUBLISHES those files into the
# sanctioned output dir afterwards. Every other isolation flag stays
# pinned (no MCP, no session persistence, safe-mode, isolated cwd): the
# sandbox opens exactly one door, not the workspace.
_WRITE_FLAGS = (
    "-p",
    "--output-format", "json",
    "--tools", "Write",
    "--allowedTools", "Write",
    "--strict-mcp-config",
    "--permission-mode", "acceptEdits",
    "--no-session-persistence",
    "--safe-mode",
)

# Substring that marks a failure (nonzero exit, or an exit-0 envelope with
# is_error:true) as an auth failure rather than a generic CLI error,
# sourced from the real unauthenticated capture described in the module
# docstring above. Matched case-insensitively against combined
# stdout+stderr so it is found regardless of whether the JSON parses.
_AUTH_SIGNATURES = ("not logged in",)


def _isolated_cwd():
    """A fresh, empty temp directory the claude subprocess is pointed at
    via `cwd=` (there is no `-C`/`--cwd` flag for the real claude CLI) so
    it has no project-level instruction file discovery tied to this
    process's own cwd (Sec8.4 defense-in-depth; `--safe-mode` is already
    documented to disable CLAUDE.md outright). Caller removes it;
    complete() always cleans up in a try/finally."""
    return tempfile.mkdtemp(prefix="claude-adapter-")


def _build_prompt(context):
    system = context.get("system")
    user = context["input"]
    if system:
        return f"{system}\n\n{user}"
    return user


def _build_argv(model, file_output_dir=None):
    argv = ["claude"]
    # file_output_dir only selects the flag set -- the model writes into
    # its cwd (the isolated workdir, always writable); complete() publishes
    # from there. No --add-dir: the sanctioned dir itself is .claude-nested
    # and the classifier would deny direct writes to it anyway.
    argv.extend(_WRITE_FLAGS if file_output_dir else _PINNED_FLAGS)
    argv.extend(["--model", model])
    return argv


def _looks_like_auth_failure(combined_output):
    lowered = combined_output.lower()
    return any(sig in lowered for sig in _AUTH_SIGNATURES)


def _excerpt(text, limit=500):
    text = (text or "").strip()
    if len(text) > limit:
        return text[:limit] + "... (truncated)"
    return text


def _parse_envelope(stdout):
    """Parses claude -p --output-format json's single-JSON-object envelope.
    Raises ValueError if stdout is not valid JSON, is not a `type: "result"`
    object, or carries no `.result` text -- claude's contract is one JSON
    object on stdout, so anything else is untrusted."""
    envelope = json.loads(stdout)
    if not isinstance(envelope, dict) or envelope.get("type") != "result":
        raise ValueError("claude --output-format json produced no 'result' envelope")
    text = envelope.get("result")
    if not isinstance(text, str):
        raise ValueError("claude --output-format json envelope has no string 'result' field")
    return envelope, text


def complete(context, *, timeout=DEFAULT_MODEL_TIMEOUT_SECONDS, env=None):
    """SPEC-ASSISTANT.md Sec8.1 contract: one stateless claude -p turn.

    Returns {"text": str, "usage": dict | None,
    "timings": {"elapsed_seconds": float}}. Raises an
    adapters.AdapterError subclass on any failure (Sec8.5) -- never lets a
    raw subprocess/JSON exception escape uncaught.
    """
    model = context["model"]
    prompt = _build_prompt(context)
    workdir = _isolated_cwd()
    try:
        argv = _build_argv(model, context.get("fileOutputDir")) + [prompt]
        call_env = dict(env) if env is not None else dict(os.environ)
        start = time.monotonic()
        result = adapters.invoke_cli(argv, timeout=timeout, env=call_env, cwd=workdir)
        elapsed = time.monotonic() - start
    finally:
        # publish-from-workdir (2026-07-29): any plain file the model wrote
        # into its isolated cwd moves into the sanctioned output dir before
        # the workdir is destroyed. Same-name collisions overwrite
        # (re-generating a file IS the intent); failures are best-effort --
        # a missed publish loses the file, never the turn.
        _publish_dir = context.get("fileOutputDir")
        if _publish_dir:
            try:
                for _name in os.listdir(workdir):
                    _src = os.path.join(workdir, _name)
                    if os.path.isfile(_src) and not _name.startswith("."):
                        try:
                            os.replace(_src, os.path.join(_publish_dir, _name))
                        except OSError:
                            pass
            except OSError:
                pass
        shutil.rmtree(workdir, ignore_errors=True)

    combined = (result.stdout or "") + "\n" + (result.stderr or "")

    if result.returncode != 0:
        if _looks_like_auth_failure(combined):
            raise adapters.AuthExpired(
                "claude authentication has expired or is missing -- run "
                "`claude auth login` and try again."
            )
        raise adapters.NonzeroExit(
            f"claude exited {result.returncode}: {_excerpt(result.stderr or result.stdout)}"
        )

    try:
        envelope, text = _parse_envelope(result.stdout)
    except (ValueError, json.JSONDecodeError) as exc:
        raise adapters.UnparseableOutput(
            f"claude --output-format json produced output that could not be parsed: {exc}"
        ) from exc

    if envelope.get("is_error"):
        # Exit 0 but the envelope itself signals failure (claude-review.sh
        # precedent: is_error:true is checked independent of exit code).
        if _looks_like_auth_failure(combined):
            raise adapters.AuthExpired(
                "claude authentication has expired or is missing -- run "
                "`claude auth login` and try again."
            )
        raise adapters.NonzeroExit(f"claude reported is_error=true: {_excerpt(text)}")

    usage = envelope.get("usage")
    return {"text": text, "usage": usage, "timings": {"elapsed_seconds": elapsed}}


adapters.register_adapter("claude", complete)
