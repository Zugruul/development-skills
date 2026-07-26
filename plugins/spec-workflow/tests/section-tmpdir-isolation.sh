#!/usr/bin/env bash
# section-tmpdir-isolation.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky
# before sourcing this file. This file assumes those are already in scope.
#
# development-skills#412: the recurring 43-fail setup-assistant cluster was
# root-caused to shared-$TMPDIR accumulation across many agent lanes over a
# session (thousands of stale mktemp entries), NOT to concurrency directly --
# a solo, locked, single suite run reproduced the cluster 3x; an otherwise
# identical run with a fresh per-run TMPDIR passed 0-fail immediately after.
# The fix: run-tests.sh mints a private TMPDIR root before sourcing any
# section, so every section's mktemp/mktemp -d calls land inside it by
# construction, and removes that root on exit (any exit path, incl. signals).
# This section proves that contract holds for every OTHER section (this file
# itself runs as one of them, so if the runner didn't set TMPDIR up first,
# these checks would see the unmodified ambient TMPDIR instead).
#
# Recursion guard: two of the checks below spawn `bash run-tests.sh` as a
# subprocess to prove per-invocation uniqueness and post-exit cleanup. A
# spawned child re-sources every section file, including THIS one; without a
# sentinel the child would spawn again forever. Every spawn below is
# prefixed _TMPDIR_ISOLATION_PROBE=<path>; when that is set we skip the
# recursive checks (the child only needs to report its own TMPDIR).
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== tmpdir-isolation =="

# 1. TMPDIR must be set to a private per-run root, not left as the ambient
#    default -- the marker pattern is the one run-tests.sh mints below.
case "${TMPDIR:-}" in
    */sw-suite-*) echo "ok   tmpdir-isolation: TMPDIR is a private per-run root" ;;
    *) echo "FAIL tmpdir-isolation: TMPDIR is a private per-run root — got: ${TMPDIR:-<unset>}"; fails=$((fails + 1)) ;;
esac

# 2. An ordinary, unqualified mktemp call lands inside that root by
#    construction (this is the whole point -- every section's existing
#    mktemp/mktemp -d calls get isolation for free, no call-site changes).
_tdi_probe="$(mktemp)"
case "$_tdi_probe" in
    "${TMPDIR:-/tmp}"/*) echo "ok   tmpdir-isolation: mktemp lands under the private TMPDIR root" ;;
    *) echo "FAIL tmpdir-isolation: mktemp lands under the private TMPDIR root — got: $_tdi_probe (TMPDIR=${TMPDIR:-<unset>})"; fails=$((fails + 1)) ;;
esac
rm -f "$_tdi_probe"

# If this IS a recursively-spawned probe child, just report our TMPDIR to
# the path the parent asked for and stop -- no further recursion.
if [[ -n "${_TMPDIR_ISOLATION_PROBE:-}" ]]; then
    printf '%s\n' "${TMPDIR:-}" >"$_TMPDIR_ISOLATION_PROBE"
    return 0 2>/dev/null || exit 0
fi

# 3. Regression pin: two separate invocations of run-tests.sh get distinct
#    private TMPDIR roots (per-run uniqueness, not a single shared root).
_tdi_out1="$(mktemp -u)"; _tdi_out2="$(mktemp -u)"
_TMPDIR_ISOLATION_PROBE="$_tdi_out1" bash "$HERE/run-tests.sh" --section tmpdir-isolation >/dev/null 2>&1
_TMPDIR_ISOLATION_PROBE="$_tdi_out2" bash "$HERE/run-tests.sh" --section tmpdir-isolation >/dev/null 2>&1
_tdi_root1="$(cat "$_tdi_out1" 2>/dev/null || echo MISSING1)"
_tdi_root2="$(cat "$_tdi_out2" 2>/dev/null || echo MISSING2)"
if [[ -n "$_tdi_root1" && "$_tdi_root1" != MISSING1 && -n "$_tdi_root2" && "$_tdi_root2" != MISSING2 && "$_tdi_root1" != "$_tdi_root2" ]]; then
    echo "ok   tmpdir-isolation: two invocations mint distinct private TMPDIR roots"
else
    echo "FAIL tmpdir-isolation: two invocations mint distinct private TMPDIR roots — got: '$_tdi_root1' vs '$_tdi_root2'"
    fails=$((fails + 1))
fi

# 4. Cleanup trap: each invocation's private root is gone once it has
#    exited (covers the normal-exit path; the trap is on EXIT which bash
#    also runs on most signals, see run-tests.sh's own comment).
if [[ -n "$_tdi_root1" && "$_tdi_root1" != MISSING1 && ! -d "$_tdi_root1" ]]; then
    echo "ok   tmpdir-isolation: first invocation's private root is removed after it exits"
else
    echo "FAIL tmpdir-isolation: first invocation's private root is removed after it exits — still present: $_tdi_root1"
    fails=$((fails + 1))
fi
if [[ -n "$_tdi_root2" && "$_tdi_root2" != MISSING2 && ! -d "$_tdi_root2" ]]; then
    echo "ok   tmpdir-isolation: second invocation's private root is removed after it exits"
else
    echo "FAIL tmpdir-isolation: second invocation's private root is removed after it exits — still present: $_tdi_root2"
    fails=$((fails + 1))
fi
rm -f "$_tdi_out1" "$_tdi_out2"
