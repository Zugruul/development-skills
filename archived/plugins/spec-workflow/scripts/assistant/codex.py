"""Codex adapter (SPEC-ASSISTANT.md Sec8.1, Sec8.2, Sec8.4, Sec8.5,
Sec17.1-Sec17.3, AST-011).

Wraps the OpenAI Codex CLI (`codex exec --json`, a subscription CLI per
Sec17.1 -- never a metered API) as one stateless `complete(context)` turn.

Context shape (Sec8.2, minimal -- AST-013 composes the real thing from
recall/budget logic; this is only what one turn NEEDS):

    context = {
        "model": str,            # passed verbatim to -m (Sec6.5: never allowlisted)
        "system": str | None,    # optional system/instructions text
        "input": str,            # the user's message for this turn
    }

`system` and `input` are joined into ONE prompt string (codex exec takes a
single positional PROMPT) with a plain blank-line join -- no shell quoting
is involved since the whole string travels as a single argv element
(Sec17.3).

Pinned isolation flags (Sec8.4 -- "no user-global instruction ingestion; no
plugin/skill surface from the dev workflow; harness tool use disabled"),
researched against codex-cli 0.144.4's `codex exec --help`:

    --json                  machine-parseable JSONL event stream (Sec8.1);
                             required to parse the completion at all.
    -s / --sandbox read-only (default, no `fileOutputDir`) or
    -s / --sandbox workspace-write (`fileOutputDir` present in context)
                             file-output variant (2026-08-01, issue #518 --
                             mirrors claude.py's own `_PINNED_FLAGS`/
                             `_WRITE_FLAGS` two-set design verbatim, gated
                             on the SAME `context["fileOutputDir"]` key,
                             round-1 review decision): a real codex-backed
                             persona hit a "file creation is blocked by the
                             current read-only sandbox" refusal live -- the
                             persona output contract (setup.py's OUT block,
                             turns.py's fileOutput system-prompt text)
                             promises every turn's workdir is WRITABLE and
                             its files get published (fee53259's
                             workdir-publish relay), and `read-only` made
                             that a lie whenever the engine had actually
                             resolved a `fileOutputDir` for this turn. Only
                             THAT case widens to `workspace-write`, paired
                             with `-C <isolated_dir>` (below) -- the SAME
                             confinement shape harness.py's own harness-job
                             sandbox posture already established (Sec9.4):
                             writes are bounded to a fresh, empty, per-turn
                             directory and nowhere else, and that directory
                             is thrown away (`shutil.rmtree`) once
                             `complete()` publishes whatever landed in it
                             via `adapters.publish_workdir_files` -- the
                             SAME shared, hardened relay claude.py's
                             `_WRITE_FLAGS` path calls (fee53259 +
                             #518's round-1 hardening). A turn with no
                             file-output dir keeps the ORIGINAL `read-only`
                             bound untouched -- this is a relocated
                             boundary for the file-output case only, not a
                             blanket loosening: the sandbox flag + isolated
                             `-C` dir are still a PINNED PAIR (Sec17
                             invariant 2) in both branches, the pair's
                             VALUES just differ by branch. GAP (unchanged
                             from before this fix, see below): there is
                             still no flag that fully disables
                             tool-calling; `-s` only bounds what a tool
                             call may DO. TMPDIR leakage (anything a shell
                             tool writes outside `-C` but inside the OS
                             temp root) is accepted in the workspace-write
                             branch the same way harness.py already
                             accepts it for harness jobs -- not a new risk
                             this change introduces, and moot in the
                             read-only branch (no leakage is possible from
                             a read-only sandbox by construction). Known
                             edge, documented not silent (docs/spec-deltas/
                             518.md): a persona with `fileOutput: false`
                             keeps the OLD read-only refusal behavior by
                             design -- setup.py's OUT block still promises
                             file output unconditionally in its prompt
                             text, so such a persona's own turns can still
                             hit a spurious-sounding refusal; narrowing
                             that prompt text to the per-persona
                             `fileOutput` flag is out of this task's scope.
    --skip-git-repo-check   lets codex run from an isolated scratch
                             directory that is not a git repo, instead of
                             requiring one.
    --ignore-user-config    skips $CODEX_HOME/config.toml -- the user-global
                             config layer is not loaded (auth still
                             resolves via CODEX_HOME per codex's own docs).
    --ignore-rules          skips user/project execpolicy .rules files.
    --ephemeral              no session file is persisted to disk -- matches
                             Sec8.1's "ONE stateless invocation".
    -C <isolated_dir>       pins codex's working root to a fresh, empty,
                             per-invocation temp directory (see
                             `_isolated_cwd()`) instead of this process's
                             own cwd. This isolates PROJECT-level
                             instructions only: an empty cwd has no
                             AGENTS.md for codex to read there. Nothing
                             from this dev workflow's own plugin/skill
                             surface is ever placed in the argv or the
                             isolated directory, so "no plugin/skill
                             surface from the dev workflow" is satisfied by
                             construction, not by a flag.

Isolated CODEX_HOME (env override, not a CLI flag -- review r1 fix):
`-C` only isolates the PROJECT-level doc. codex ALSO reads an AGENTS.md out
of `$CODEX_HOME` itself regardless of `-C` (verified against real
codex-cli 0.144.4 via `codex debug prompt-input`), so a populated real
`~/.codex/AGENTS.md` would otherwise land in every turn's context
unconditionally -- `--ignore-user-config` only skips `config.toml`, not
this. `complete()` therefore builds a fresh, per-invocation `CODEX_HOME`
(see `_isolated_codex_home()`) containing ONLY a copy of the real
`auth.json` (if one exists) -- no AGENTS.md, no config.toml -- and passes
it via `env["CODEX_HOME"]` to the subprocess. Auth is preserved (the copy
is real, not a symlink into a directory we then wipe) while the global doc
never travels. This is what actually satisfies Sec8.4's "no user-global
instruction ingestion" clause; `-C` alone did not.

DOCUMENTED GAP (Sec8.4 third clause, Sec16 -- report in the AST-011
handoff; candidate for docs/spec-deltas/AST-011.md; boundary value updated
2026-08-01 per issue #518, see docs/spec-deltas/518.md): codex-cli 0.144.4
has no discovered flag or `-c` config key that fully disables the model's
ability to REQUEST a tool/shell call mid-turn ("harness tool use disabled")
-- `--sandbox` only bounds what such a call may DO, whichever value is
pinned for this turn. A turn is not currently guaranteed to be pure
text-in/text-out; it is guaranteed to be side-effect-bounded to `-C`'s
isolated, throwaway workdir -- read-only by default, or workspace-write
(issue #518) exactly when this turn's context carries a `fileOutputDir`,
so the workdir-publish relay has files to relay.

Output parsing provenance:
  - SUCCESS path (`item.completed`/agent_message text, `turn.completed`/
    usage): ASSUMED from codex's documented --json event schema. Not
    captured against a real authenticated completion (auth + cost are out
    of scope here; real-CLI use is dogfood-only per Sec16) -- flag for
    dogfood validation.
  - AUTH-FAILURE / NONZERO-EXIT paths: validated against a REAL
    unauthenticated `codex exec --json` run captured on this machine
    (codex-cli 0.144.4, isolated CODEX_HOME) -- exit code 1, and a JSONL
    stream ending in a `turn.failed` event whose `error.message` contains
    "401 Unauthorized" / "Missing bearer or basic authentication". No
    login instruction string ever appears in codex's own output -- the
    AuthExpired message below is this adapter's OWN text, not parsed from
    codex.
"""
import json
import os
import shutil
import tempfile
import time

from assistant import adapters

DEFAULT_MODEL_TIMEOUT_SECONDS = 60

_PINNED_FLAGS = (
    "--json",
    "-s", "read-only",
    "--skip-git-repo-check",
    "--ignore-user-config",
    "--ignore-rules",
    "--ephemeral",
)

# File-output variant (2026-08-01, issue #518 -- round-1 review decision:
# gate on context["fileOutputDir"] exactly like claude.py's own
# _PINNED_FLAGS/_WRITE_FLAGS split, not an unconditional widening). See the
# module docstring's `-s` bullet for the full reasoning: only a turn that
# actually has a sanctioned output dir to publish into gets
# `workspace-write`; every other turn keeps `-s read-only` untouched.
_WRITE_FLAGS = (
    "--json",
    "-s", "workspace-write",
    "--skip-git-repo-check",
    "--ignore-user-config",
    "--ignore-rules",
    "--ephemeral",
)

# Substrings that mark a nonzero exit as an auth failure rather than a
# generic CLI error, sourced from the real unauthenticated capture
# described in the module docstring above. Matched case-insensitively
# against combined stdout+stderr so both the JSONL error text and the
# plain-text ERROR log line (codex prints both) are covered.
_AUTH_SIGNATURES = ("401 unauthorized", "missing bearer or basic authentication")


def _isolated_cwd():
    """A fresh, empty temp directory codex is pointed at via -C so it has no
    project AGENTS.md/instructions file to ingest (Sec8.4). Caller removes
    it; complete() always cleans up in a try/finally."""
    return tempfile.mkdtemp(prefix="codex-adapter-")


def _real_codex_home():
    """The CODEX_HOME this process would otherwise use -- honors an
    existing CODEX_HOME env var (so a caller that has already isolated its
    own CODEX_HOME is respected) and falls back to codex's own default,
    ~/.codex."""
    return os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")


def _isolated_codex_home():
    """A fresh, per-invocation CODEX_HOME containing ONLY a copy of the
    real auth.json (if one exists) -- no AGENTS.md, no config.toml. See the
    module docstring's "Isolated CODEX_HOME" section for why this exists:
    -C alone does not stop codex from reading a global AGENTS.md out of
    CODEX_HOME itself. Copying (never symlinking) auth.json means removing
    this directory afterwards never touches the real credential. Caller
    removes it; complete() always cleans up in a try/finally."""
    real_home = _real_codex_home()
    isolated = tempfile.mkdtemp(prefix="codex-adapter-home-")
    real_auth = os.path.join(real_home, "auth.json")
    if os.path.isfile(real_auth):
        shutil.copy2(real_auth, os.path.join(isolated, "auth.json"))
    return isolated


def _build_prompt(context):
    system = context.get("system")
    user = context["input"]
    if system:
        return f"{system}\n\n{user}"
    return user


def _build_argv(model, workdir, file_output_dir=None):
    argv = ["codex", "exec"]
    argv.extend(_WRITE_FLAGS if file_output_dir else _PINNED_FLAGS)
    argv.extend(["-m", model, "-C", workdir])
    return argv


def _looks_like_auth_failure(combined_output):
    lowered = combined_output.lower()
    return any(sig in lowered for sig in _AUTH_SIGNATURES)


def _parse_jsonl(stdout):
    """Parses codex exec --json's JSONL stream into (text, usage). Raises
    ValueError on the first line that is not valid JSON, or if no
    item.completed/agent_message event is found at all -- codex's contract
    is one JSON object per line, so a single malformed line means the whole
    stream is untrusted."""
    text = None
    usage = None
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        etype = event.get("type")
        if etype == "item.completed":
            item = event.get("item") or {}
            if item.get("type") == "agent_message":
                text = item.get("text", "")
        elif etype == "turn.completed":
            usage = event.get("usage")
    if text is None:
        raise ValueError(
            "no item.completed agent_message event found in codex --json output"
        )
    return text, usage


def complete(context, *, timeout=DEFAULT_MODEL_TIMEOUT_SECONDS, env=None):
    """SPEC-ASSISTANT.md Sec8.1 contract: one stateless codex exec turn.

    Returns {"text": str, "usage": dict | None,
    "timings": {"elapsed_seconds": float}}. Raises an
    adapters.AdapterError subclass on any failure (Sec8.5) -- never lets a
    raw subprocess/JSON exception escape uncaught.
    """
    model = context["model"]
    prompt = _build_prompt(context)
    workdir = _isolated_cwd()
    codex_home = _isolated_codex_home()
    file_output_dir = context.get("fileOutputDir")
    try:
        argv = _build_argv(model, workdir, file_output_dir) + [prompt]
        # Isolation is a hard invariant, not an opt-in: whatever env the
        # caller supplies (or the inherited os.environ, if none), CODEX_HOME
        # is always overridden to the isolated one built above -- a caller
        # can never accidentally re-expose the real CODEX_HOME.
        call_env = dict(env) if env is not None else dict(os.environ)
        call_env["CODEX_HOME"] = codex_home
        start = time.monotonic()
        # cwd=workdir (round-1 review, issue #518): `-C` is codex's OWN
        # flag for pinning its working root, but the CHILD PROCESS itself
        # still inherits this process's real cwd (a live repo) at Popen
        # time unless told otherwise -- belt-and-suspenders, the same
        # defense-in-depth harness.py and claude.py already both apply
        # (harness.py's codex path passes `cwd=workdir` alongside `-C` too;
        # claude.py has no `-C` equivalent at all and relies on `cwd=`
        # alone). Never relied upon in place of `-C` -- both are pinned.
        result = adapters.invoke_cli(argv, timeout=timeout, env=call_env, cwd=workdir)
        elapsed = time.monotonic() - start
    finally:
        # publish-from-workdir (2026-08-01, issue #518): any plain file the
        # model wrote into its pinned `-C` workdir (writable only when this
        # turn requested file output -- see `_WRITE_FLAGS` above) moves
        # into the sanctioned output dir before the workdir is destroyed,
        # via adapters.py's ONE shared, hardened implementation
        # (cross-filesystem-safe, symlink- and hardlink-rejecting -- see
        # its own docstring) -- the SAME relay claude.py's complete() calls
        # (fee53259 + #518's round-1 hardening). The sandbox-flag change
        # above only opens the door for the file-output case; this step is
        # what actually walks a file through it, which is the part that
        # was missing for codex turns before this fix.
        if file_output_dir:
            adapters.publish_workdir_files(workdir, file_output_dir)
        shutil.rmtree(workdir, ignore_errors=True)
        shutil.rmtree(codex_home, ignore_errors=True)

    combined = (result.stdout or "") + "\n" + (result.stderr or "")

    if result.returncode != 0:
        if _looks_like_auth_failure(combined):
            raise adapters.AuthExpired(
                "codex authentication has expired or is missing -- run "
                "`codex login` and try again."
            )
        excerpt = (result.stderr or result.stdout or "").strip()
        if len(excerpt) > 500:
            excerpt = excerpt[:500] + "... (truncated)"
        raise adapters.NonzeroExit(f"codex exec exited {result.returncode}: {excerpt}")

    try:
        text, usage = _parse_jsonl(result.stdout)
    except (ValueError, json.JSONDecodeError) as exc:
        raise adapters.UnparseableOutput(
            f"codex exec --json produced output that could not be parsed: {exc}"
        ) from exc

    return {"text": text, "usage": usage, "timings": {"elapsed_seconds": elapsed}}


adapters.register_adapter("codex", complete)
adapters.register_adapter("openai", complete)
