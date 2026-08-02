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

# ---------------------------------------------------------- missing binary (issue #408)
# No stub-codex on PATH at all here -- an empty directory, so the real
# `codex` executable genuinely cannot be found by Popen. This is exactly
# the runner-vs-local divergence behind #408: a dev machine with the real
# codex CLI installed never exercises this path, but a CI runner without
# it does, and previously that FileNotFoundError escaped invoke_cli as a
# raw traceback instead of a clean adapters.AdapterError.
AA_EMPTY_PATH_DIR="$(mktemp -d)"
AA_PYTHON3="$(command -v python3)"
cat >"$AA_TMPPY/missing.py" <<PYEOF
from assistant import adapters, codex

context = {"model": "gpt-5.6-sol", "system": None, "input": "hi"}
try:
    codex.complete(context, timeout=10)
    print("NO_ERROR_RAISED")
except adapters.NotFound as exc:
    print("GOT_NOT_FOUND")
    print("MESSAGE_NAMES_CODEX", "codex" in str(exc))
PYEOF
out="$(PATH="$AA_EMPTY_PATH_DIR" PYTHONPATH="$AA_SCRIPTS" "$AA_PYTHON3" "$AA_TMPPY/missing.py" 2>&1)"
check "missing binary: raises adapters.NotFound instead of an escaping FileNotFoundError (issue #408)" "GOT_NOT_FOUND" "$out"
check "missing binary: message names codex" "MESSAGE_NAMES_CODEX True" "$out"
check_absent "missing binary: no raw Python traceback leaked" "Traceback (most recent call last)" "$out"
rm -rf "$AA_EMPTY_PATH_DIR"

# aa_sandbox_value <argv_file> -- extracts just the -s flag's value line
# (round-1 review NIT: a whole-dump substring check_absent for "read-only"
# is brittle -- a user message could coincidentally contain that
# substring; scoping to the actual -s VALUE line is precise regardless).
aa_sandbox_value() {
    awk '/^-s$/{getline; print; exit}' "$1"
}

# ---------------------------------------------------------- argv: pinned flags + single-element injection (no fileOutputDir -> answer-only turn)
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
# A turn with no fileOutputDir in context is an answer-only turn (Sec8.4)
# -- it keeps the ORIGINAL -s read-only bound untouched (round-1 review
# decision: gate the widened sandbox on context["fileOutputDir"] exactly
# like claude.py's own _PINNED_FLAGS/_WRITE_FLAGS split, not an
# unconditional change for every codex turn).
check "argv: -s read-only is pinned when no fileOutputDir is in context" "read-only" "$(aa_sandbox_value "$aa_argv_file")"
check_absent "argv: -s value is NOT workspace-write when no fileOutputDir is in context" "workspace-write" "$(aa_sandbox_value "$aa_argv_file")"
check "argv: --skip-git-repo-check is pinned" "--skip-git-repo-check" "$argv_contents"
check "argv: --ignore-user-config is pinned (no user-global config ingestion)" "--ignore-user-config" "$argv_contents"
check "argv: --ignore-rules is pinned" "--ignore-rules" "$argv_contents"
check "argv: --ephemeral is pinned (stateless turn)" "--ephemeral" "$argv_contents"
check "argv: -C isolated working root is pinned" "-C" "$argv_contents"
check "argv: injection payload arrives as one literal argv line (no shell reinterpretation)" \
    "hello; rm -rf /tmp/should-not-run && echo pwned" "$argv_contents"
argv_line_count="$(grep -cF -- "hello; rm -rf /tmp/should-not-run && echo pwned" "$aa_argv_file")"
check_rc "argv: injection payload is exactly ONE argv line, not split" 1 "$argv_line_count"

# regression: no approvals/sandbox bypass ever leaks in, in either flag set.
check_absent "argv: no dangerously-bypass-approvals-and-sandbox flag ever leaks in" \
    "dangerously-bypass-approvals-and-sandbox" "$argv_contents"
check_absent "argv: no full-auto flag ever leaks in" "full-auto" "$argv_contents"

# cwd pin (round-1 review, issue #518): -C is codex's OWN flag for pinning
# its working root, but the CHILD PROCESS still inherits this process's
# real cwd at Popen time unless told otherwise -- codex.py now also pins
# `cwd=workdir` on the invoke_cli call, belt-and-suspenders alongside -C,
# matching harness.py's own codex-path precedent and claude.py's cwd=
# (its only mechanism, having no -C equivalent at all).
aa_cwd_file="$(mktemp)"
aa_cwd_argv_file="$(mktemp)"
out="$(PATH="$AA_STUB_BIN:$PATH" CODEX_STUB_MODE=ok CODEX_STUB_CWD_FILE="$aa_cwd_file" CODEX_STUB_ARGV_FILE="$aa_cwd_argv_file" PYTHONPATH="$AA_SCRIPTS" python3 "$AA_TMPPY/argv.py" 2>&1)"
check "cwd pin: completes without error" "DONE" "$out"
aa_stub_cwd="$(cat "$aa_cwd_file")"
check_absent "cwd pin: the stub's cwd is NOT this test process's cwd" "$PWD" "$aa_stub_cwd"
# round-2 review: pin the EQUALITY, not just "differs from the test's own
# cwd" -- the child's actual cwd must be the exact same directory codex.py
# pinned via -C, not merely SOME other directory.
aa_c_value="$(awk '/^-C$/{getline; print; exit}' "$aa_cwd_argv_file")"
check "cwd pin: child cwd EQUALS the recorded -C value exactly" "$aa_c_value" "$aa_stub_cwd"
rm -f "$aa_cwd_file" "$aa_cwd_argv_file"

# ---------------------------------------------------------- argv + publish relay: workdir file -> fileOutputDir (issue #518, fileOutputDir present -> workspace-write)
# fee53259 built the workdir-publish relay (a file the model writes as a
# plain filename into its isolated turn workdir gets moved into the
# sanctioned `fileOutputDir` before the workdir is destroyed) but only
# wired it into claude.py -- codex.py's complete() never read
# context["fileOutputDir"] at all, so a codex-backed persona's file was
# thrown away with the rest of the workdir on every turn. This proves the
# relay now runs for codex too, AND that a fileOutputDir turn is exactly
# the one that gets the widened sandbox: the stub writes a file into the
# `-C` directory codex.py pinned, and the test asserts both the argv
# (workspace-write, not read-only) and the behavior (the file survives
# into a fresh, separate `fileOutputDir` handed in via context).
AA_PUBLISH_DIR="$(mktemp -d)"
aa_publish_argv_file="$(mktemp)"
cat >"$AA_TMPPY/publish.py" <<PYEOF
import os
from assistant import codex

publish_dir = os.environ["AA_PUBLISH_DIR"]
context = {
    "model": "gpt-5.6-sol",
    "system": None,
    "input": "make me a 3D model",
    "fileOutputDir": publish_dir,
}
codex.complete(context, timeout=10)
print("PUBLISHED", sorted(os.listdir(publish_dir)))
with open(os.path.join(publish_dir, "duck.obj")) as fh:
    print("CONTENT", fh.read().strip())
PYEOF
out="$(PATH="$AA_STUB_BIN:$PATH" CODEX_STUB_MODE=ok CODEX_STUB_WRITE_FILE=duck.obj \
    CODEX_STUB_ARGV_FILE="$aa_publish_argv_file" \
    AA_PUBLISH_DIR="$AA_PUBLISH_DIR" PYTHONPATH="$AA_SCRIPTS" python3 "$AA_TMPPY/publish.py" 2>&1)"
check "publish relay: a file the stub wrote into its -C workdir is published to fileOutputDir" \
    "PUBLISHED ['duck.obj']" "$out"
check "publish relay: the published file's content survives the move" "CONTENT stub file content" "$out"
check "publish relay argv: -s workspace-write is pinned when fileOutputDir IS in context (issue #518)" \
    "workspace-write" "$(aa_sandbox_value "$aa_publish_argv_file")"
check_absent "publish relay argv: -s value is NOT read-only when fileOutputDir IS in context" \
    "read-only" "$(aa_sandbox_value "$aa_publish_argv_file")"
check "publish relay argv: -C isolated working root is still pinned" "-C" "$(cat "$aa_publish_argv_file")"
rm -rf "$AA_PUBLISH_DIR"
rm -f "$aa_publish_argv_file"

# publish relay: absent fileOutputDir (fileOutput disabled / not a chat
# turn) means no publish attempt at all -- the workdir file is just thrown
# away with the rest of the workdir, exactly like before this fix.
cat >"$AA_TMPPY/nopublish.py" <<PYEOF
from assistant import codex

context = {"model": "gpt-5.6-sol", "system": None, "input": "hi"}
codex.complete(context, timeout=10)
print("DONE")
PYEOF
out="$(PATH="$AA_STUB_BIN:$PATH" CODEX_STUB_MODE=ok CODEX_STUB_WRITE_FILE=duck.obj PYTHONPATH="$AA_SCRIPTS" python3 "$AA_TMPPY/nopublish.py" 2>&1)"
check "publish relay: no fileOutputDir in context still completes cleanly" "DONE" "$out"

# ---------------------------------------------------------- publish relay hardening: cross-filesystem fallback (round-1 review item 1)
# A reviewer reproduced total silent loss with a RAM-disk temp root: the
# original loop's bare os.replace cannot cross filesystem boundaries
# (EXDEV) and its `except OSError: pass` swallowed that. Simulates the
# boundary by monkeypatching os.replace to raise OSError on its FIRST call
# only (the direct src->dst attempt across the simulated device boundary --
# realistic EXDEV only fires cross-device; the fallback's OWN final
# tmp->dst replace, round-2 review item 1, stays within publish_dir, same
# device, and must still succeed) and asserts adapters.publish_workdir_files
# still lands the file via its atomic temp-then-replace fallback.
AA_XDEV_DIR="$(mktemp -d)"
cat >"$AA_TMPPY/xdev.py" <<PYEOF
import os
from assistant import codex

publish_dir = os.environ["AA_XDEV_DIR"]

# os is one shared singleton module object regardless of which import path
# reaches it -- patching os.replace here affects the SAME attribute
# adapters.publish_workdir_files (and its _copy_into_publish_dir fallback)
# call via their own "import os", no second import path needed.
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
        "model": "gpt-5.6-sol",
        "system": None,
        "input": "make me a 3D model",
        "fileOutputDir": publish_dir,
    }
    codex.complete(context, timeout=10)
finally:
    os.replace = real_replace

print("PUBLISHED", sorted(os.listdir(publish_dir)))
with open(os.path.join(publish_dir, "duck.obj")) as fh:
    print("CONTENT", fh.read().strip())
PYEOF
out="$(PATH="$AA_STUB_BIN:$PATH" CODEX_STUB_MODE=ok CODEX_STUB_WRITE_FILE=duck.obj AA_XDEV_DIR="$AA_XDEV_DIR" PYTHONPATH="$AA_SCRIPTS" python3 "$AA_TMPPY/xdev.py" 2>&1)"
check "cross-filesystem fallback: the file still lands when os.replace raises (simulated EXDEV)" \
    "PUBLISHED ['duck.obj']" "$out"
check "cross-filesystem fallback: content survives the copy+remove fallback" "CONTENT stub file content" "$out"
rm -rf "$AA_XDEV_DIR"

# ---------------------------------------------------------- publish relay hardening: atomic temp-then-replace on the copy fallback (round-2 review item 1)
# A mid-copy failure (e.g. ENOSPC) inside the cross-filesystem fallback
# must never leave a partially-written file sitting at the FINAL name --
# engine.py's own before/after os.listdir diff would see it and mint a
# truncated artifact as if it were the model's real output. Calls
# adapters.publish_workdir_files directly (not through codex.complete(),
# which destroys the workdir immediately after) so the test can inspect
# both sides afterward: publish_dir must carry neither the final name NOR
# a leftover temp file, and the ORIGINAL file must still be sitting in the
# workdir untouched (never removed, since the copy never finished).
AA_ATOMIC_WORKDIR="$(mktemp -d)"
AA_ATOMIC_PUBLISH_DIR="$(mktemp -d)"
printf '%s' "original content" >"$AA_ATOMIC_WORKDIR/duck.obj"
cat >"$AA_TMPPY/atomic.py" <<PYEOF
import os
import shutil
import adapters

workdir = os.environ["AA_ATOMIC_WORKDIR"]
publish_dir = os.environ["AA_ATOMIC_PUBLISH_DIR"]

# Force the fallback path (os.replace always fails here -- this test only
# cares about what happens ONCE inside the copy fallback, not about
# reaching it realistically). The fake copy2 WRITES PARTIAL BYTES to
# whatever destination path it is actually given before raising -- this is
# the load-bearing part of the test: it writes to the FINAL name directly
# with the pre-round-2 implementation (no temp indirection), but to a TEMP
# name with the round-2 fix, so only the round-2 fix's own cleanup can keep
# that partial write from ever reaching publish_dir's final name.
def _boom_copy2(src, dst2, *a, **kw):
    with open(dst2, "w") as fh:
        fh.write("PARTIAL-GARBAGE-FROM-INTERRUPTED-COPY")
    raise OSError(28, "No space left on device")
os.replace = lambda *a, **kw: (_ for _ in ()).throw(OSError(18, "Invalid cross-device link"))
shutil.copy2 = _boom_copy2

adapters.publish_workdir_files(workdir, publish_dir)

print("PUBLISH_DIR_CONTENTS", sorted(os.listdir(publish_dir)))
print("WORKDIR_CONTENTS", sorted(os.listdir(workdir)))
with open(os.path.join(workdir, "duck.obj")) as fh:
    print("SRC_CONTENT", fh.read())
PYEOF
out="$(AA_ATOMIC_WORKDIR="$AA_ATOMIC_WORKDIR" AA_ATOMIC_PUBLISH_DIR="$AA_ATOMIC_PUBLISH_DIR" PYTHONPATH="$AA_SCRIPTS/assistant" python3 "$AA_TMPPY/atomic.py" 2>&1)"
check "atomic fallback: publish dir carries NO partial/final file when copy2 fails mid-way" \
    "PUBLISH_DIR_CONTENTS []" "$out"
check "atomic fallback: the source file is preserved in the workdir (never removed on failure)" \
    "WORKDIR_CONTENTS ['duck.obj']" "$out"
check "atomic fallback: the preserved source's content is untouched" "SRC_CONTENT original content" "$out"
rm -rf "$AA_ATOMIC_WORKDIR" "$AA_ATOMIC_PUBLISH_DIR"

# ---------------------------------------------------------- publish relay hardening: symlink rejected (round-1 review item 4)
# A model-written SYMLINK in the workdir must never be published: os.replace
# moves the link itself, so publishing it would hand the chat media
# library / /file route a link to whatever arbitrary path this process can
# already read. Points the symlink at a canary file with known secret
# content and asserts neither the link NOR the secret content ever reaches
# fileOutputDir.
AA_SYMLINK_PUBLISH_DIR="$(mktemp -d)"
AA_CANARY="$AA_TMPPY/canary-secret.txt"
printf '%s\n' "TOP SECRET -- must never be published" >"$AA_CANARY"
cat >"$AA_TMPPY/symlink.py" <<PYEOF
import os
from assistant import codex

publish_dir = os.environ["AA_SYMLINK_PUBLISH_DIR"]
context = {
    "model": "gpt-5.6-sol",
    "system": None,
    "input": "hi",
    "fileOutputDir": publish_dir,
}
codex.complete(context, timeout=10)
print("PUBLISHED", sorted(os.listdir(publish_dir)))
PYEOF
out="$(PATH="$AA_STUB_BIN:$PATH" CODEX_STUB_MODE=ok \
    CODEX_STUB_WRITE_SYMLINK=leak.txt CODEX_STUB_SYMLINK_TARGET="$AA_CANARY" \
    AA_SYMLINK_PUBLISH_DIR="$AA_SYMLINK_PUBLISH_DIR" PYTHONPATH="$AA_SCRIPTS" python3 "$AA_TMPPY/symlink.py" 2>&1)"
check "symlink rejected: publish dir ends up empty, not carrying the link" "PUBLISHED []" "$out"
check_absent "symlink rejected: the linked file's own name never appears in the publish dir" \
    "leak.txt" "$(ls -A "$AA_SYMLINK_PUBLISH_DIR" 2>/dev/null)"
rm -rf "$AA_SYMLINK_PUBLISH_DIR"

# ---------------------------------------------------------- publish relay hardening: hardlink rejected (round-1 review item 4)
# A file with st_nlink > 1 (a HARDLINK) survives an os.path.islink check
# but still exposes the linked file's real content once moved/copied --
# same threat as the symlink case, a different channel. The stub hardlinks
# the requested name onto a real file it writes in the SAME -C directory
# (guaranteed same filesystem); neither name should be published.
AA_HARDLINK_PUBLISH_DIR="$(mktemp -d)"
cat >"$AA_TMPPY/hardlink.py" <<PYEOF
import os
from assistant import codex

publish_dir = os.environ["AA_HARDLINK_PUBLISH_DIR"]
context = {
    "model": "gpt-5.6-sol",
    "system": None,
    "input": "hi",
    "fileOutputDir": publish_dir,
}
codex.complete(context, timeout=10)
print("PUBLISHED", sorted(os.listdir(publish_dir)))
PYEOF
out="$(PATH="$AA_STUB_BIN:$PATH" CODEX_STUB_MODE=ok CODEX_STUB_WRITE_HARDLINK=leak2.txt \
    AA_HARDLINK_PUBLISH_DIR="$AA_HARDLINK_PUBLISH_DIR" PYTHONPATH="$AA_SCRIPTS" python3 "$AA_TMPPY/hardlink.py" 2>&1)"
check "hardlink rejected: publish dir ends up empty, not carrying the hardlinked name" "PUBLISHED []" "$out"
check_absent "hardlink rejected: the hardlinked file's own name never appears in the publish dir" \
    "leak2.txt" "$(ls -A "$AA_HARDLINK_PUBLISH_DIR" 2>/dev/null)"
rm -rf "$AA_HARDLINK_PUBLISH_DIR"

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
# AST-012 registers "claude" (see section-assistant-claude.sh for the full
# claude-adapter contract + provider-switch proof) -- this section only
# asserts the codex/openai seam still resolves and an actually-unknown
# provider still fails cleanly.
cat >"$AA_TMPPY/registry.py" <<PYEOF
from assistant import adapters

fn = adapters.get_adapter("openai")
print("GOT_CODEX_ADAPTER", fn is not None)
try:
    adapters.get_adapter("not-a-real-provider")
    print("UNKNOWN_UNEXPECTEDLY_REGISTERED")
except KeyError as exc:
    print("UNKNOWN_PROVIDER_CLEAN_KEYERROR", "not-a-real-provider" in str(exc))
PYEOF
out="$(PYTHONPATH="$AA_SCRIPTS" python3 "$AA_TMPPY/registry.py" 2>&1)"
check "registry: get_adapter('openai') resolves to the codex adapter" "GOT_CODEX_ADAPTER True" "$out"
check "registry: get_adapter('not-a-real-provider') is a clean KeyError" "UNKNOWN_PROVIDER_CLEAN_KEYERROR True" "$out"

# ---------------------------------------------------------- argv-array invariant (Sec17.3): no shell=True anywhere
adapter_src="$AA_SCRIPTS/assistant/adapters.py"
codex_src="$AA_SCRIPTS/assistant/codex.py"
check_absent "invariant: adapters.py never uses shell=True" "shell=True" "$(cat "$adapter_src")"
check_absent "invariant: codex.py never uses shell=True" "shell=True" "$(cat "$codex_src")"
check_absent "invariant: adapters.py never calls os.system" "os.system" "$(cat "$adapter_src")"
check_absent "invariant: codex.py never calls os.system" "os.system" "$(cat "$codex_src")"

rm -rf "$AA_TMPPY" "$aa_argv_file"
