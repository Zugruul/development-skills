#!/usr/bin/env bash
# section-plugin-root.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
#
# Covers CDX-001 (docs/BACKLOG-CODEX-COMPAT.md / SPEC-CODEX-COMPAT.md §6.3,
# §6.4, §14): the shared plugin-root resolver, bash + python. Every probe
# below cd's to an unrelated tmp dir before invoking the resolver and
# explicitly controls both override env vars, so no assertion here can pass
# or fail because of the caller's real CWD or ambient environment (SPEC
# §12: plugin-root resolution never reads CWD).
# shellcheck disable=SC2016  # the bash -c '...' probe bodies below are single-quoted on
# purpose -- they're expanded inside the spawned bash -c, not at this call site.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== plugin-root resolver (CDX-001) =="

RESOLVER_SH="$PLUGIN/scripts/lib/plugin-root.sh"
RESOLVER_PY_DIR="$PLUGIN/scripts/lib"

# mktemp -d on macOS returns a path under /var, which is itself a symlink to
# /private/var -- the bash resolver walks up via `cd -P`/`pwd -P` (physical,
# symlinks resolved), so an unresolved /var/... expectation would spuriously
# mismatch a correctly-resolved /private/var/... result. Canonicalize every
# tmp dir we create as a fixture, once, right after mktemp, so expectations
# and results are compared in the same (physical) form.
_pr_realdir() { ( cd -P "$1" 2>/dev/null && pwd -P ); }

_PR_ELSEWHERE="$(_pr_realdir "$(mktemp -d)")"

# --- scenario a: resolution from the source checkout ------------------------
out="$(cd "$_PR_ELSEWHERE" && env -u SPEC_WORKFLOW_PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT bash -c '
    set -uo pipefail
    source "$1"
    spec_workflow_plugin_root
' _ "$RESOLVER_SH" 2>&1)"
check "bash: source-checkout resolution" "$PLUGIN" "$out"

out="$(cd "$_PR_ELSEWHERE" && env -u SPEC_WORKFLOW_PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from plugin_root import resolve_plugin_root
print(resolve_plugin_root())
' "$RESOLVER_PY_DIR" 2>&1)"
check "python: source-checkout resolution" "$PLUGIN" "$out"

# --- scenario b: an "installed" copy at a different absolute path -----------
_PR_INSTALLED_BASE="$(_pr_realdir "$(mktemp -d)")"
_PR_INSTALLED="$_PR_INSTALLED_BASE/installed-copy"
mkdir -p "$_PR_INSTALLED"
cp -R "$PLUGIN"/. "$_PR_INSTALLED"/

out="$(cd "$_PR_ELSEWHERE" && env -u SPEC_WORKFLOW_PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT bash -c '
    source "$1"
    spec_workflow_plugin_root
' _ "$_PR_INSTALLED/scripts/lib/plugin-root.sh" 2>&1)"
check "bash: installed-copy resolution (different absolute path)" "$_PR_INSTALLED" "$out"
check_absent "bash: installed-copy does not fall back to the source checkout" "$PLUGIN" "$out"

out="$(cd "$_PR_ELSEWHERE" && env -u SPEC_WORKFLOW_PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from plugin_root import resolve_plugin_root
print(resolve_plugin_root())
' "$_PR_INSTALLED/scripts/lib" 2>&1)"
check "python: installed-copy resolution (different absolute path)" "$_PR_INSTALLED" "$out"

# --- scenario c: a path containing spaces -----------------------------------
_PR_SPACED_BASE="$(_pr_realdir "$(mktemp -d)")"
_PR_SPACED="$_PR_SPACED_BASE/installed copy with spaces"
mkdir -p "$_PR_SPACED"
cp -R "$PLUGIN"/. "$_PR_SPACED"/

out="$(cd "$_PR_ELSEWHERE" && env -u SPEC_WORKFLOW_PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT bash -c '
    source "$1"
    spec_workflow_plugin_root
' _ "$_PR_SPACED/scripts/lib/plugin-root.sh" 2>&1)"
check "bash: path-with-spaces resolution" "$_PR_SPACED" "$out"

out="$(cd "$_PR_ELSEWHERE" && env -u SPEC_WORKFLOW_PLUGIN_ROOT -u CLAUDE_PLUGIN_ROOT python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from plugin_root import resolve_plugin_root
print(resolve_plugin_root())
' "$_PR_SPACED/scripts/lib" 2>&1)"
check "python: path-with-spaces resolution" "$_PR_SPACED" "$out"

# --- scenario d: an explicit override pointing at a VALID plugin root -------
_PR_FAKE_ROOT="$(_pr_realdir "$(mktemp -d)")/fake-root"
mkdir -p "$_PR_FAKE_ROOT/.claude-plugin"
printf '{"name":"fake"}' > "$_PR_FAKE_ROOT/.claude-plugin/plugin.json"

out="$(cd "$_PR_ELSEWHERE" && SPEC_WORKFLOW_PLUGIN_ROOT="$_PR_FAKE_ROOT" bash -c '
    source "$1"
    spec_workflow_plugin_root
' _ "$RESOLVER_SH" 2>&1)"
check "bash: valid SPEC_WORKFLOW_PLUGIN_ROOT override wins" "$_PR_FAKE_ROOT" "$out"

out="$(cd "$_PR_ELSEWHERE" && SPEC_WORKFLOW_PLUGIN_ROOT="$_PR_FAKE_ROOT" python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from plugin_root import resolve_plugin_root
print(resolve_plugin_root())
' "$RESOLVER_PY_DIR" 2>&1)"
check "python: valid SPEC_WORKFLOW_PLUGIN_ROOT override wins" "$_PR_FAKE_ROOT" "$out"

# SPEC_WORKFLOW_PLUGIN_ROOT must outrank CLAUDE_PLUGIN_ROOT (§5 precedence),
# and CLAUDE_PLUGIN_ROOT alone must still work as Claude Code's fast path.
_PR_FAKE_ROOT2="$(_pr_realdir "$(mktemp -d)")/fake-root-2"
mkdir -p "$_PR_FAKE_ROOT2/.codex-plugin"
printf '{}' > "$_PR_FAKE_ROOT2/.codex-plugin/plugin.json"

out="$(cd "$_PR_ELSEWHERE" && SPEC_WORKFLOW_PLUGIN_ROOT="$_PR_FAKE_ROOT" CLAUDE_PLUGIN_ROOT="$_PR_FAKE_ROOT2" bash -c '
    source "$1"
    spec_workflow_plugin_root
' _ "$RESOLVER_SH" 2>&1)"
check "bash: SPEC_WORKFLOW_PLUGIN_ROOT outranks CLAUDE_PLUGIN_ROOT" "$_PR_FAKE_ROOT" "$out"

out="$(cd "$_PR_ELSEWHERE" && env -u SPEC_WORKFLOW_PLUGIN_ROOT CLAUDE_PLUGIN_ROOT="$_PR_FAKE_ROOT2" bash -c '
    source "$1"
    spec_workflow_plugin_root
' _ "$RESOLVER_SH" 2>&1)"
check "bash: CLAUDE_PLUGIN_ROOT fast path (Claude Code) still honored" "$_PR_FAKE_ROOT2" "$out"

# --- scenario e: an explicit override pointing at an INVALID/nonexistent dir,
# which must fail loudly and NOT silently fall through to sentinel discovery.
_PR_INVALID="$_PR_ELSEWHERE/does-not-exist-$$"

rc=0
out="$(cd "$_PR_ELSEWHERE" && SPEC_WORKFLOW_PLUGIN_ROOT="$_PR_INVALID" bash -c '
    source "$1"
    spec_workflow_plugin_root
' _ "$RESOLVER_SH" 2>&1)" || rc=$?
check_rc "bash: invalid SPEC_WORKFLOW_PLUGIN_ROOT (nonexistent dir) fails" 1 "$rc"
check "bash: invalid-override error names the bad path" "$_PR_INVALID" "$out"
check_absent "bash: invalid override does NOT fall through to sentinel discovery" "$PLUGIN" "$out"

rc=0
out="$(cd "$_PR_ELSEWHERE" && SPEC_WORKFLOW_PLUGIN_ROOT="$_PR_ELSEWHERE" bash -c '
    source "$1"
    spec_workflow_plugin_root
' _ "$RESOLVER_SH" 2>&1)" || rc=$?
check_rc "bash: override pointing at an existing dir WITHOUT the sentinel fails" 1 "$rc"

rc=0
out="$(cd "$_PR_ELSEWHERE" && SPEC_WORKFLOW_PLUGIN_ROOT="$_PR_INVALID" python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from plugin_root import resolve_plugin_root
print(resolve_plugin_root())
' "$RESOLVER_PY_DIR" 2>&1)" || rc=$?
check_rc "python: invalid SPEC_WORKFLOW_PLUGIN_ROOT (nonexistent dir) raises" 1 "$rc"
check "python: invalid-override error names the bad path" "$_PR_INVALID" "$out"

rc=0
out="$(cd "$_PR_ELSEWHERE" && SPEC_WORKFLOW_PLUGIN_ROOT="$_PR_ELSEWHERE" python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from plugin_root import resolve_plugin_root
print(resolve_plugin_root())
' "$RESOLVER_PY_DIR" 2>&1)" || rc=$?
check_rc "python: override pointing at an existing dir WITHOUT the sentinel raises" 1 "$rc"

# --- scenario f (review round 1, code-quality finding #1): a symlink CYCLE
# in the resolver's own on-disk location must fail loudly, not hang. The
# manual single-hop symlink walk in _spec_workflow_pr_resolver_dir uses
# `[[ -L ]]`/`readlink` (lstat + one-shot readlink, NOT a kernel open()/stat()
# that follows the full chain), so it gets none of the kernel's own ELOOP
# protection -- an unbounded version of that loop spins forever on a genuine
# a.sh<->b.sh cycle. A real `source` of such a file can never itself succeed
# (the kernel WOULD ELOOP on open()), so the only way to exercise the buggy
# walk is to hand the helper a path into the cycle directly -- exactly what a
# BASH_SOURCE[0] value would look like if the resolver script's own location
# were ever reached through such a cycle. `_pr_bounded` runs the probe in a
# background subshell with an independent watcher that SIGKILLs it if it
# outlives the wall-clock cap, so a regression here fails this test instead
# of hanging the whole suite (no `timeout`/`gtimeout` binary is assumed).
_pr_bounded() { # secs cmd...
    local secs="$1"; shift
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) &
    local watcher=$!
    wait "$pid" 2>/dev/null; local rc=$?
    kill "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
    return $rc
}

_PR_CYCLE="$(_pr_realdir "$(mktemp -d)")"
ln -s b.sh "$_PR_CYCLE/a.sh"
ln -s a.sh "$_PR_CYCLE/b.sh"

_PR_CYCLE_OUT="$(mktemp)"
_pr_bounded 5 bash -c '
    source "$1"
    _spec_workflow_pr_resolver_dir "$2"
' _ "$RESOLVER_SH" "$_PR_CYCLE/a.sh" >"$_PR_CYCLE_OUT" 2>&1
cyc_rc=$?
cyc_out="$(cat "$_PR_CYCLE_OUT")"
rm -f "$_PR_CYCLE_OUT"
check_rc "bash: symlink cycle fails loud within the wall-clock cap (not SIGKILLed)" 1 "$cyc_rc"
check "bash: symlink cycle error mentions a symlink loop/limit" "symlink" "$cyc_out"

rm -rf "$_PR_ELSEWHERE" "$_PR_INSTALLED_BASE" "$_PR_SPACED_BASE" "$_PR_CYCLE" \
    "$(dirname "$_PR_FAKE_ROOT")" "$(dirname "$_PR_FAKE_ROOT2")"
