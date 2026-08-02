#!/usr/bin/env bash
# section-assistant-claude.sh -- AST-012: claude adapter -- isolation,
# no-tools, timeout, provider-switch (SPEC-ASSISTANT.md Sec8.1, Sec8.4,
# Sec8.5, Sec17.1-Sec17.3, issue #310). Sourced by run-tests.sh; do not run
# standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant claude adapter (AST-012: claude adapter, argv-array, mandatory timeout, provider-switch, SPEC-ASSISTANT.md Sec8) =="

AC_SCRIPTS="$PLUGIN/scripts"
AC_STUB_BIN="$FIX/stub-claude"

# ac_run <mode> <python-body-file> -- runs python3 with the stub claude on
# PATH, CLAUDE_STUB_MODE=<mode>, and a fresh CLAUDE_STUB_ARGV_FILE. Captures
# combined stdout (the python body prints its own markers; check() greps
# them). The python body is written to a real file (not a heredoc inside
# this $() capture) so quoting stays simple and bash-3.2-safe.
ac_argv_file=""
ac_run() {
    local mode="$1" body="$2"
    ac_argv_file="$(mktemp)"
    PATH="$AC_STUB_BIN:$PATH" \
        CLAUDE_STUB_MODE="$mode" \
        CLAUDE_STUB_ARGV_FILE="$ac_argv_file" \
        PYTHONPATH="$AC_SCRIPTS" \
        python3 "$body"
}

AC_TMPPY="$(mktemp -d)"

# ---------------------------------------------------------- ok: valid completion
cat >"$AC_TMPPY/ok.py" <<PYEOF
from assistant import claude

context = {"model": "claude-fable-5", "system": "You are terse.", "input": "hi"}
result = claude.complete(context, timeout=10)
print("TEXT", result["text"])
print("USAGE_INPUT", result["usage"]["input_tokens"])
print("USAGE_OUTPUT", result["usage"]["output_tokens"])
print("HAS_TIMINGS", "elapsed_seconds" in result["timings"])
PYEOF
out="$(ac_run ok "$AC_TMPPY/ok.py" 2>&1)"
check "ok: returns stub result text" "TEXT Hello from stub" "$out"
check "ok: returns usage.input_tokens" "USAGE_INPUT 10" "$out"
check "ok: returns usage.output_tokens" "USAGE_OUTPUT 5" "$out"
check "ok: returns a timings dict with elapsed_seconds" "HAS_TIMINGS True" "$out"

# ---------------------------------------------------------- nonzero exit
cat >"$AC_TMPPY/nonzero.py" <<PYEOF
from assistant import adapters, claude

context = {"model": "claude-fable-5", "system": None, "input": "hi"}
try:
    claude.complete(context, timeout=10)
    print("NO_ERROR_RAISED")
except adapters.NonzeroExit as exc:
    print("GOT_NONZERO_EXIT")
    print("MESSAGE_HAS_EXCERPT", "disk full" in str(exc))
PYEOF
out="$(ac_run nonzero "$AC_TMPPY/nonzero.py" 2>&1)"
check "nonzero exit: raises adapters.NonzeroExit" "GOT_NONZERO_EXIT" "$out"
check "nonzero exit: message carries the stderr excerpt" "MESSAGE_HAS_EXCERPT True" "$out"

# ---------------------------------------------------------- timeout (short override)
cat >"$AC_TMPPY/hang.py" <<PYEOF
import time
from assistant import adapters, claude

context = {"model": "claude-fable-5", "system": None, "input": "hi"}
start = time.monotonic()
try:
    claude.complete(context, timeout=1)
    print("NO_ERROR_RAISED")
except adapters.Timeout as exc:
    elapsed = time.monotonic() - start
    print("GOT_TIMEOUT")
    print("BOUNDED", elapsed < 10)
PYEOF
out="$(ac_run hang "$AC_TMPPY/hang.py" 2>&1)"
check "hang: raises adapters.Timeout within the short override bound" "GOT_TIMEOUT" "$out"
check "hang: kills the process well inside a 10s bound (not the 30s sleep)" "BOUNDED True" "$out"

# ---------------------------------------------------------- garbage stdout
cat >"$AC_TMPPY/garbage.py" <<PYEOF
from assistant import adapters, claude

context = {"model": "claude-fable-5", "system": None, "input": "hi"}
try:
    claude.complete(context, timeout=10)
    print("NO_ERROR_RAISED")
except adapters.UnparseableOutput as exc:
    print("GOT_UNPARSEABLE")
PYEOF
out="$(ac_run garbage "$AC_TMPPY/garbage.py" 2>&1)"
check "garbage stdout: raises adapters.UnparseableOutput" "GOT_UNPARSEABLE" "$out"

# ---------------------------------------------------------- auth-expired
cat >"$AC_TMPPY/auth.py" <<PYEOF
from assistant import adapters, claude

context = {"model": "claude-fable-5", "system": None, "input": "hi"}
try:
    claude.complete(context, timeout=10)
    print("NO_ERROR_RAISED")
except adapters.AuthExpired as exc:
    print("GOT_AUTH_EXPIRED")
    print("MESSAGE_HAS_LOGIN_INSTRUCTION", "claude auth login" in str(exc))
PYEOF
out="$(ac_run auth "$AC_TMPPY/auth.py" 2>&1)"
check "auth-expired: raises adapters.AuthExpired (real-capture corpus fixture)" "GOT_AUTH_EXPIRED" "$out"
check "auth-expired: message instructs claude auth login" "MESSAGE_HAS_LOGIN_INSTRUCTION True" "$out"

# ---------------------------------------------------------- argv: pinned flags + single-element injection
cat >"$AC_TMPPY/argv.py" <<PYEOF
from assistant import claude

payload = "hello; rm -rf /tmp/should-not-run && echo pwned"
context = {"model": "claude-fable-5", "system": None, "input": payload}
claude.complete(context, timeout=10)
print("DONE")
PYEOF
# ac_run's own CLAUDE_STUB_ARGV_FILE is set inside a subshell (the $(...)
# capture below), so its assignment to $ac_argv_file never reaches this
# parent shell -- mint the path here instead and invoke the stub directly.
ac_argv_file="$(mktemp)"
out="$(PATH="$AC_STUB_BIN:$PATH" CLAUDE_STUB_MODE=ok CLAUDE_STUB_ARGV_FILE="$ac_argv_file" PYTHONPATH="$AC_SCRIPTS" python3 "$AC_TMPPY/argv.py" 2>&1)"
check "argv: completes without error" "DONE" "$out"
argv_contents="$(cat "$ac_argv_file")"
check "argv: -p is pinned" "-p" "$argv_contents"
check "argv: --output-format json is pinned" "json" "$argv_contents"
check "argv: --tools is pinned (harness tool use fully disabled)" "--tools" "$argv_contents"
check "argv: --strict-mcp-config is pinned (no plugin/skill MCP surface)" "--strict-mcp-config" "$argv_contents"
check "argv: --permission-mode plan is pinned (read-only, defense-in-depth)" "plan" "$argv_contents"
check "argv: --no-session-persistence is pinned (stateless turn)" "--no-session-persistence" "$argv_contents"
check "argv: --safe-mode is pinned (no CLAUDE.md/skills/plugins/hooks/MCP ingestion, auth preserved)" "--safe-mode" "$argv_contents"
check "argv: --model is pinned" "--model" "$argv_contents"
check "argv: injection payload arrives as one literal argv line (no shell reinterpretation)" \
    "hello; rm -rf /tmp/should-not-run && echo pwned" "$argv_contents"
argv_line_count="$(grep -cF -- "hello; rm -rf /tmp/should-not-run && echo pwned" "$ac_argv_file")"
check_rc "argv: injection payload is exactly ONE argv line, not split" 1 "$argv_line_count"

# ------------------------------------------- isolated cwd (mirrors codex's -C)
# The real claude CLI has no -C/--cwd flag (Sec8.4 GAP, see claude.py's
# docstring) -- complete() isolates the project-instruction-discovery
# surface by pointing the subprocess's OWN cwd (via invoke_cli's `cwd=`) at
# a fresh, empty, per-invocation temp directory instead of this process's
# cwd. Proves that mechanism is real, not merely documented.
cat >"$AC_TMPPY/cwd.py" <<PYEOF
from assistant import claude

context = {"model": "claude-fable-5", "system": None, "input": "hi"}
claude.complete(context, timeout=10)
print("DONE")
PYEOF
ac_cwd_file="$(mktemp)"
out="$(PATH="$AC_STUB_BIN:$PATH" CLAUDE_STUB_MODE=ok CLAUDE_STUB_CWD_FILE="$ac_cwd_file" PYTHONPATH="$AC_SCRIPTS" python3 "$AC_TMPPY/cwd.py" 2>&1)"
check "isolated cwd: completes without error" "DONE" "$out"
ac_stub_cwd="$(cat "$ac_cwd_file")"
check_absent "isolated cwd: the stub's cwd is NOT this test process's cwd" "$PWD" "$ac_stub_cwd"
rm -f "$ac_cwd_file"

# ---------------------------------------------------------- publish relay: workdir file -> fileOutputDir (issue #518 round-1 review item 1: fee53259 shipped zero tests for this)
# fee53259 built the workdir-publish relay for claude.py but shipped no
# test covering it at all. The stub already receives `cwd=` pointed at the
# isolated workdir (see the isolated-cwd test above), so it can write
# directly into os.getcwd() -- proves a file the model writes there is
# published into `fileOutputDir` before the workdir is destroyed.
AC_PUBLISH_DIR="$(mktemp -d)"
cat >"$AC_TMPPY/publish.py" <<PYEOF
import os
from assistant import claude

publish_dir = os.environ["AC_PUBLISH_DIR"]
context = {
    "model": "claude-fable-5",
    "system": None,
    "input": "make me a 3D model",
    "fileOutputDir": publish_dir,
}
claude.complete(context, timeout=10)
print("PUBLISHED", sorted(os.listdir(publish_dir)))
with open(os.path.join(publish_dir, "duck.obj")) as fh:
    print("CONTENT", fh.read().strip())
PYEOF
out="$(PATH="$AC_STUB_BIN:$PATH" CLAUDE_STUB_MODE=ok CLAUDE_STUB_WRITE_FILE=duck.obj AC_PUBLISH_DIR="$AC_PUBLISH_DIR" PYTHONPATH="$AC_SCRIPTS" python3 "$AC_TMPPY/publish.py" 2>&1)"
check "publish relay: a file the stub wrote into its isolated cwd is published to fileOutputDir" \
    "PUBLISHED ['duck.obj']" "$out"
check "publish relay: the published file's content survives the move" "CONTENT stub file content" "$out"
rm -rf "$AC_PUBLISH_DIR"

# ---------------------------------------------------------- publish relay hardening: cross-filesystem fallback (round-1 review item 1)
# Same reviewer-reproduced bug as codex.py's: os.replace cannot cross
# filesystem boundaries and the original loop's except OSError: pass
# swallowed that silently. Both adapters now call the ONE shared
# adapters.publish_workdir_files, so this proves the fallback for the
# claude integration path too, not just codex's. Fails ONLY the first
# os.replace call (the direct src->dst attempt across the simulated device
# boundary) -- the fallback's OWN final tmp->dst replace (round-2 review
# item 1) stays within publish_dir, same device, and must still succeed.
AC_XDEV_DIR="$(mktemp -d)"
cat >"$AC_TMPPY/xdev.py" <<PYEOF
import os
from assistant import claude

publish_dir = os.environ["AC_XDEV_DIR"]
real_replace = os.replace
_calls = {"n": 0}
def _boom_once(*a, **kw):
    _calls["n"] += 1
    if _calls["n"] == 1:
        raise OSError(18, "Invalid cross-device link")
    return real_replace(*a, **kw)
os.replace = _boom_once
try:
    context = {
        "model": "claude-fable-5",
        "system": None,
        "input": "make me a 3D model",
        "fileOutputDir": publish_dir,
    }
    claude.complete(context, timeout=10)
finally:
    os.replace = real_replace
print("PUBLISHED", sorted(os.listdir(publish_dir)))
with open(os.path.join(publish_dir, "duck.obj")) as fh:
    print("CONTENT", fh.read().strip())
PYEOF
out="$(PATH="$AC_STUB_BIN:$PATH" CLAUDE_STUB_MODE=ok CLAUDE_STUB_WRITE_FILE=duck.obj AC_XDEV_DIR="$AC_XDEV_DIR" PYTHONPATH="$AC_SCRIPTS" python3 "$AC_TMPPY/xdev.py" 2>&1)"
check "cross-filesystem fallback: the file still lands when os.replace raises (simulated EXDEV)" \
    "PUBLISHED ['duck.obj']" "$out"
check "cross-filesystem fallback: content survives the copy+remove fallback" "CONTENT stub file content" "$out"
rm -rf "$AC_XDEV_DIR"

# ---------------------------------------------------------- publish relay hardening: symlink + hardlink rejected (round-1 review item 4)
# Both adapters share adapters.publish_workdir_files's loop -- proves the
# claude integration path rejects the same hostile-link channels
# section-assistant-adapter.sh already pins for codex.
AC_SYMLINK_PUBLISH_DIR="$(mktemp -d)"
AC_CANARY="$AC_TMPPY/canary-secret.txt"
printf '%s\n' "TOP SECRET -- must never be published" >"$AC_CANARY"
cat >"$AC_TMPPY/symlink.py" <<PYEOF
import os
from assistant import claude

publish_dir = os.environ["AC_SYMLINK_PUBLISH_DIR"]
context = {"model": "claude-fable-5", "system": None, "input": "hi", "fileOutputDir": publish_dir}
claude.complete(context, timeout=10)
print("PUBLISHED", sorted(os.listdir(publish_dir)))
PYEOF
out="$(PATH="$AC_STUB_BIN:$PATH" CLAUDE_STUB_MODE=ok \
    CLAUDE_STUB_WRITE_SYMLINK=leak.txt CLAUDE_STUB_SYMLINK_TARGET="$AC_CANARY" \
    AC_SYMLINK_PUBLISH_DIR="$AC_SYMLINK_PUBLISH_DIR" PYTHONPATH="$AC_SCRIPTS" python3 "$AC_TMPPY/symlink.py" 2>&1)"
check "symlink rejected: publish dir ends up empty, not carrying the link" "PUBLISHED []" "$out"
rm -rf "$AC_SYMLINK_PUBLISH_DIR"

AC_HARDLINK_PUBLISH_DIR="$(mktemp -d)"
cat >"$AC_TMPPY/hardlink.py" <<PYEOF
import os
from assistant import claude

publish_dir = os.environ["AC_HARDLINK_PUBLISH_DIR"]
context = {"model": "claude-fable-5", "system": None, "input": "hi", "fileOutputDir": publish_dir}
claude.complete(context, timeout=10)
print("PUBLISHED", sorted(os.listdir(publish_dir)))
PYEOF
out="$(PATH="$AC_STUB_BIN:$PATH" CLAUDE_STUB_MODE=ok CLAUDE_STUB_WRITE_HARDLINK=leak2.txt \
    AC_HARDLINK_PUBLISH_DIR="$AC_HARDLINK_PUBLISH_DIR" PYTHONPATH="$AC_SCRIPTS" python3 "$AC_TMPPY/hardlink.py" 2>&1)"
check "hardlink rejected: publish dir ends up empty, not carrying the hardlinked name" "PUBLISHED []" "$out"
rm -rf "$AC_HARDLINK_PUBLISH_DIR"

# ---------------------------------------------------------- registry seam + provider-switch (config-only)
cat >"$AC_TMPPY/registry.py" <<PYEOF
from assistant import adapters, claude, codex

claude_fn = adapters.get_adapter("claude")
openai_fn = adapters.get_adapter("openai")
print("CLAUDE_RESOLVED", claude_fn is claude.complete)
print("OPENAI_RESOLVED", openai_fn is codex.complete)
print("DIFFERENT_CALLABLES", claude_fn is not openai_fn)
PYEOF
out="$(PYTHONPATH="$AC_SCRIPTS" python3 "$AC_TMPPY/registry.py" 2>&1)"
check "registry: get_adapter('claude') resolves to the claude adapter" "CLAUDE_RESOLVED True" "$out"
check "registry: get_adapter('openai') resolves to the codex adapter" "OPENAI_RESOLVED True" "$out"
check "registry: claude and openai are different registered callables" "DIFFERENT_CALLABLES True" "$out"

# provider-switch: SAME calling code (adapters.get_adapter(provider)(context,
# **kwargs)) drives BOTH stub binaries to a successful completion, proving
# switching provider is config-only (SPEC-ASSISTANT.md Sec8.1 acceptance
# criterion) -- no branch in the calling code names "claude" or "codex".
AC_STUB_CODEX_BIN="$FIX/stub-codex"
cat >"$AC_TMPPY/switch.py" <<PYEOF
import os
from assistant import adapters

def drive(provider, context, **kwargs):
    fn = adapters.get_adapter(provider)
    return fn(context, **kwargs)

context = {"model": "some-model", "system": None, "input": "hi"}
result = drive(os.environ["AC_PROVIDER"], context, timeout=10)
print("TEXT", result["text"])
PYEOF
out_claude="$(PATH="$AC_STUB_BIN:$PATH" CLAUDE_STUB_MODE=ok AC_PROVIDER=claude PYTHONPATH="$AC_SCRIPTS" python3 "$AC_TMPPY/switch.py" 2>&1)"
check "provider-switch: same calling code drives the claude stub" "TEXT Hello from stub" "$out_claude"
out_openai="$(PATH="$AC_STUB_CODEX_BIN:$PATH" CODEX_STUB_MODE=ok AC_PROVIDER=openai PYTHONPATH="$AC_SCRIPTS" python3 "$AC_TMPPY/switch.py" 2>&1)"
check "provider-switch: the SAME calling code drives the codex stub too (config-only switch)" "TEXT Hello from stub" "$out_openai"

# ---------------------------------------------------------- argv-array invariant (Sec17.3): no shell=True anywhere
claude_src="$AC_SCRIPTS/assistant/claude.py"
check_absent "invariant: claude.py never uses shell=True" "shell=True" "$(cat "$claude_src")"
check_absent "invariant: claude.py never calls os.system" "os.system" "$(cat "$claude_src")"

rm -rf "$AC_TMPPY" "$ac_argv_file"
