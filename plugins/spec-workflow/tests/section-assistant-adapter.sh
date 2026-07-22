#!/usr/bin/env bash
# section-assistant-adapter.sh -- AST-011: adapter interface + codex adapter
# -- isolation, no-tools, timeout (SPEC-ASSISTANT.md Sec8.1, Sec8.4, Sec8.5,
# Sec17.1-Sec17.3, issue #309). Sourced by run-tests.sh; do not run
# standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant adapter (AST-011: codex adapter, argv-array, mandatory timeout, SPEC-ASSISTANT.md Sec8) =="

AA_SCRIPTS="$PLUGIN/scripts"
AA_STUB_BIN="$FIX/stub-codex"

# aa_run <mode> <python-body-file> -- runs python3 with the stub codex on
# PATH, CODEX_STUB_MODE=<mode>, and a fresh CODEX_STUB_ARGV_FILE. Captures
# combined stdout (the python body prints its own markers; check() greps
# them). The python body is written to a real file (not a heredoc inside
# this $() capture) so quoting stays simple and bash-3.2-safe.
aa_argv_file=""
aa_run() {
    local mode="$1" body="$2"
    aa_argv_file="$(mktemp)"
    PATH="$AA_STUB_BIN:$PATH" \
        CODEX_STUB_MODE="$mode" \
        CODEX_STUB_ARGV_FILE="$aa_argv_file" \
        PYTHONPATH="$AA_SCRIPTS" \
        python3 "$body"
}

AA_TMPPY="$(mktemp -d)"

# ---------------------------------------------------------- ok: valid completion
cat >"$AA_TMPPY/ok.py" <<PYEOF
from assistant import codex

context = {"model": "gpt-5.6-sol", "system": "You are terse.", "input": "hi"}
result = codex.complete(context, timeout=10)
print("TEXT", result["text"])
print("USAGE_INPUT", result["usage"]["input_tokens"])
print("USAGE_OUTPUT", result["usage"]["output_tokens"])
print("HAS_TIMINGS", "elapsed_seconds" in result["timings"])
PYEOF
out="$(aa_run ok "$AA_TMPPY/ok.py" 2>&1)"
check "ok: returns stub agent_message text" "TEXT Hello from stub" "$out"
check "ok: returns usage.input_tokens" "USAGE_INPUT 10" "$out"
check "ok: returns usage.output_tokens" "USAGE_OUTPUT 5" "$out"
check "ok: returns a timings dict with elapsed_seconds" "HAS_TIMINGS True" "$out"

# ---------------------------------------------------------- nonzero exit
cat >"$AA_TMPPY/nonzero.py" <<PYEOF
from assistant import adapters, codex

context = {"model": "gpt-5.6-sol", "system": None, "input": "hi"}
try:
    codex.complete(context, timeout=10)
    print("NO_ERROR_RAISED")
except adapters.NonzeroExit as exc:
    print("GOT_NONZERO_EXIT")
    print("MESSAGE_HAS_EXCERPT", "disk full" in str(exc))
PYEOF
out="$(aa_run nonzero "$AA_TMPPY/nonzero.py" 2>&1)"
check "nonzero exit: raises adapters.NonzeroExit" "GOT_NONZERO_EXIT" "$out"
check "nonzero exit: message carries the stderr excerpt" "MESSAGE_HAS_EXCERPT True" "$out"

# ---------------------------------------------------------- timeout (short override)
cat >"$AA_TMPPY/hang.py" <<PYEOF
import time
from assistant import adapters, codex

context = {"model": "gpt-5.6-sol", "system": None, "input": "hi"}
start = time.monotonic()
try:
    codex.complete(context, timeout=1)
    print("NO_ERROR_RAISED")
except adapters.Timeout as exc:
    elapsed = time.monotonic() - start
    print("GOT_TIMEOUT")
    print("BOUNDED", elapsed < 10)
PYEOF
out="$(aa_run hang "$AA_TMPPY/hang.py" 2>&1)"
check "hang: raises adapters.Timeout within the short override bound" "GOT_TIMEOUT" "$out"
check "hang: kills the process well inside a 10s bound (not the 30s sleep)" "BOUNDED True" "$out"

# ---------------------------------------------------------- garbage stdout
cat >"$AA_TMPPY/garbage.py" <<PYEOF
from assistant import adapters, codex

context = {"model": "gpt-5.6-sol", "system": None, "input": "hi"}
try:
    codex.complete(context, timeout=10)
    print("NO_ERROR_RAISED")
except adapters.UnparseableOutput as exc:
    print("GOT_UNPARSEABLE")
PYEOF
out="$(aa_run garbage "$AA_TMPPY/garbage.py" 2>&1)"
check "garbage stdout: raises adapters.UnparseableOutput" "GOT_UNPARSEABLE" "$out"

# ---------------------------------------------------------- auth-expired
cat >"$AA_TMPPY/auth.py" <<PYEOF
from assistant import adapters, codex

context = {"model": "gpt-5.6-sol", "system": None, "input": "hi"}
try:
    codex.complete(context, timeout=10)
    print("NO_ERROR_RAISED")
except adapters.AuthExpired as exc:
    print("GOT_AUTH_EXPIRED")
    print("MESSAGE_HAS_LOGIN_INSTRUCTION", "codex login" in str(exc))
PYEOF
out="$(aa_run auth "$AA_TMPPY/auth.py" 2>&1)"
check "auth-expired: raises adapters.AuthExpired (corpus-sourced 401 fixture)" "GOT_AUTH_EXPIRED" "$out"
check "auth-expired: message instructs codex login" "MESSAGE_HAS_LOGIN_INSTRUCTION True" "$out"

# ---------------------------------------------------------- argv: pinned flags + single-element injection
cat >"$AA_TMPPY/argv.py" <<PYEOF
from assistant import codex

payload = "hello; rm -rf /tmp/should-not-run && echo pwned"
context = {"model": "gpt-5.6-sol", "system": None, "input": payload}
codex.complete(context, timeout=10)
print("DONE")
PYEOF
# aa_run's own CODEX_STUB_ARGV_FILE is set inside a subshell (the $(...)
# capture below), so its assignment to $aa_argv_file never reaches this
# parent shell -- mint the path here instead and invoke the stub directly.
aa_argv_file="$(mktemp)"
out="$(PATH="$AA_STUB_BIN:$PATH" CODEX_STUB_MODE=ok CODEX_STUB_ARGV_FILE="$aa_argv_file" PYTHONPATH="$AA_SCRIPTS" python3 "$AA_TMPPY/argv.py" 2>&1)"
check "argv: completes without error" "DONE" "$out"
argv_contents="$(cat "$aa_argv_file")"
check "argv: --json is pinned" "--json" "$argv_contents"
check "argv: -s read-only is pinned (sandboxed tool effects)" "read-only" "$argv_contents"
check "argv: --skip-git-repo-check is pinned" "--skip-git-repo-check" "$argv_contents"
check "argv: --ignore-user-config is pinned (no user-global config ingestion)" "--ignore-user-config" "$argv_contents"
check "argv: --ignore-rules is pinned" "--ignore-rules" "$argv_contents"
check "argv: --ephemeral is pinned (stateless turn)" "--ephemeral" "$argv_contents"
check "argv: -C isolated working root is pinned" "-C" "$argv_contents"
check "argv: injection payload arrives as one literal argv line (no shell reinterpretation)" \
    "hello; rm -rf /tmp/should-not-run && echo pwned" "$argv_contents"
argv_line_count="$(grep -cF -- "hello; rm -rf /tmp/should-not-run && echo pwned" "$aa_argv_file")"
check_rc "argv: injection payload is exactly ONE argv line, not split" 1 "$argv_line_count"

# ------------------------------------------- CODEX_HOME isolation (review r1 blocker)
# codex reads an AGENTS.md out of $CODEX_HOME itself regardless of -C
# (verified against real codex-cli 0.144.4 via `codex debug prompt-input`)
# -- a populated real ~/.codex/AGENTS.md must never reach a turn. Simulates
# a "real" CODEX_HOME (with both auth.json and a canary AGENTS.md) via the
# CODEX_HOME env var codex.py's _real_codex_home() honors, then asserts the
# adapter hands the stub a DIFFERENT, isolated CODEX_HOME that carries the
# auth.json copy (login preserved) but no AGENTS.md (no ingestion).
aa_fake_real_home="$(mktemp -d)"
printf '%s\n' '{"token": "fake-auth-token-canary"}' >"$aa_fake_real_home/auth.json"
printf '%s\n' 'GLOBAL CANARY INSTRUCTION -- must never reach a turn' >"$aa_fake_real_home/AGENTS.md"
cat >"$AA_TMPPY/home.py" <<PYEOF
from assistant import codex

context = {"model": "gpt-5.6-sol", "system": None, "input": "hi"}
codex.complete(context, timeout=10)
print("DONE")
PYEOF
aa_home_file="$(mktemp)"
out="$(PATH="$AA_STUB_BIN:$PATH" CODEX_STUB_MODE=ok CODEX_HOME="$aa_fake_real_home" CODEX_STUB_HOME_FILE="$aa_home_file" PYTHONPATH="$AA_SCRIPTS" python3 "$AA_TMPPY/home.py" 2>&1)"
check "CODEX_HOME isolation: completes without error" "DONE" "$out"
aa_home_contents="$(cat "$aa_home_file")"
check "CODEX_HOME isolation: adapter passes a CODEX_HOME to the stub" "CODEX_HOME=" "$aa_home_contents"
check_absent "CODEX_HOME isolation: the passed CODEX_HOME is NOT the real/fake home dir" "CODEX_HOME=$aa_fake_real_home" "$aa_home_contents"
check "CODEX_HOME isolation: isolated home carries the auth.json copy (login preserved)" "HAS_AUTH=True" "$aa_home_contents"
check "CODEX_HOME isolation: copied auth.json content matches the real one" "AUTH_CONTENT={\"token\": \"fake-auth-token-canary\"}" "$aa_home_contents"
check "CODEX_HOME isolation: isolated home carries NO AGENTS.md (no user-global instruction ingestion)" "HAS_AGENTS=False" "$aa_home_contents"
rm -rf "$aa_fake_real_home" "$aa_home_file"

# ---------------------------------------------------------- registry seam
cat >"$AA_TMPPY/registry.py" <<PYEOF
from assistant import adapters

fn = adapters.get_adapter("openai")
print("GOT_CODEX_ADAPTER", fn is not None)
try:
    adapters.get_adapter("claude")
    print("CLAUDE_UNEXPECTEDLY_REGISTERED")
except KeyError as exc:
    print("CLAUDE_NOT_YET_REGISTERED", "claude" not in str(exc) or True)
PYEOF
out="$(PYTHONPATH="$AA_SCRIPTS" python3 "$AA_TMPPY/registry.py" 2>&1)"
check "registry: get_adapter('openai') resolves to the codex adapter" "GOT_CODEX_ADAPTER True" "$out"
check "registry: get_adapter('claude') is a clean not-yet-implemented seam (KeyError)" "CLAUDE_NOT_YET_REGISTERED" "$out"

# ---------------------------------------------------------- argv-array invariant (Sec17.3): no shell=True anywhere
adapter_src="$AA_SCRIPTS/assistant/adapters.py"
codex_src="$AA_SCRIPTS/assistant/codex.py"
check_absent "invariant: adapters.py never uses shell=True" "shell=True" "$(cat "$adapter_src")"
check_absent "invariant: codex.py never uses shell=True" "shell=True" "$(cat "$codex_src")"
check_absent "invariant: adapters.py never calls os.system" "os.system" "$(cat "$adapter_src")"
check_absent "invariant: codex.py never calls os.system" "os.system" "$(cat "$codex_src")"

rm -rf "$AA_TMPPY" "$aa_argv_file"
