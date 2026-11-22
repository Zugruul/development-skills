#!/usr/bin/env bash
# section-suite-temp-guard.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail, has sourced _lib.sh
# (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky.
#
# Incident 2026-11-21: a suite run pushed 67 fixture commits to GitHub main.
# The outer run's exit removed its temp root while a nested run
# (section-runner-filter.sh) was still going; the nested run's root lived
# INSIDE the outer one, so its `mktemp -d` calls failed and returned "",
# helpers turned "" into the current directory, and fixture git commands
# (init, commit, branch -m, remote remove, push) ran in the real checkout.
#
# Proven here end to end, in a throwaway checkout (never the real one): a copy
# of this runner runs a probe section from inside a git checkout with an
# origin; mid-run the test removes the "outer" root, then the run's own root.
# The checkout and its origin must come out byte-for-byte untouched:
#   * a nested run keeps its own root when the outer root goes away;
#   * a failed mktemp stops the run with an error;
#   * an empty path never becomes the current directory (cd "" refused);
#   * fixture git refuses to write outside the run's temp root, from bash and
#     from any child process (python here), since the guard is a PATH shim.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
if [[ -n "${_STG_SIG:-}" ]]; then
    return 0  # never recurse when a probe run re-sources the registered sections
fi
echo "== suite temp root guard (incident 2026-11-21) =="

STG="$(mktemp -d)"
[[ -n "$STG" && -d "$STG" ]] || { echo "FATAL: mktemp -d failed (suite-temp-guard)" >&2; exit 1; }
STG="$( (builtin cd -P "$STG" && pwd -P) )"
_stg_g() { git -c user.email=t@t -c user.name=t "$@"; }

# --- the throwaway checkout: a copy of the runner + a probe section, with an origin
_stg_tests="$STG/repo/plugins/spec-workflow/tests"
git init -q --bare -b main "$STG/origin.git"
git init -q -b main "$STG/repo"
mkdir -p "$_stg_tests"
cp "$HERE/run-tests.sh" "$HERE/_lib.sh" "$_stg_tests/"
[[ -d "$HERE/lib" ]] && cp -R "$HERE/lib" "$_stg_tests/"
python3 - "$_stg_tests/run-tests.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
assert "SECTIONS=(\n" in s
open(p, "w").write(s.replace("SECTIONS=(\n", "SECTIONS=(\n    section-zz-vanish-probe.sh\n", 1))
PY
cat >"$_stg_tests/section-zz-vanish-probe.sh" <<'PROBE'
echo "== vanish probe =="
printf '%s\n' "${TMPDIR:-}" >"$_STG_SIG/root"
_i=0
while [[ ! -e "$_STG_SIG/go" && $_i -lt 600 ]]; do sleep 0.1; _i=$((_i + 1)); done
if [[ "${_STG_MODE:-}" == empty ]]; then d=""; else d="$(mktemp -d)"; fi
git -C "$d" init -q
git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "fixture escaped"
git -C "$d" branch -m escaped
git -C "$d" push -q origin HEAD:refs/heads/escaped
python3 -c 'import subprocess, sys; subprocess.run(["git", "-C", sys.argv[1] or ".", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "escaped via python"])' "$d"
git -C "$d" remote remove origin
( cd "$d" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m "escaped via cd" )
echo "probe-finished" >"$_STG_SIG/finished"
PROBE
git -C "$STG/repo" add -A && _stg_g -C "$STG/repo" commit -q -m "checkout under test"
git -C "$STG/repo" remote add origin "$STG/origin.git"
git -C "$STG/repo" push -q origin main 2>/dev/null

_stg_snap() {
    git -C "$STG/repo" for-each-ref --format='%(refname) %(objectname)'
    git -C "$STG/repo" rev-parse HEAD
    git -C "$STG/repo" status --porcelain
    git -C "$STG/repo" rev-list --all --count
    cat "$STG/repo/.git/config"
    git -C "$STG/origin.git" for-each-ref --format='%(refname) %(objectname)'
}
_stg_before="$(_stg_snap)"

# _stg_probe <mode> <outer-root>: start the probe run in the background from inside the checkout
_stg_probe() {
    rm -rf "$STG/sig" && mkdir -p "$STG/sig"
    ( builtin cd "$STG/repo" && TMPDIR="$2" _STG_SIG="$STG/sig" _STG_MODE="$1" \
        bash plugins/spec-workflow/tests/run-tests.sh --section zz-vanish-probe >"$STG/probe-$1.log" 2>&1
      echo "$?" >"$STG/sig/rc" ) &
    _stg_pid=$!
    _i=0
    while [[ ! -s "$STG/sig/root" && $_i -lt 600 ]]; do sleep 0.1; _i=$((_i + 1)); done
}

# --- 1. the outer root, then the run's own root, disappear mid-run
_stg_outer="$(mktemp -d)"
[[ -n "$_stg_outer" && -d "$_stg_outer" ]] || { echo "FATAL: mktemp -d failed (suite-temp-guard outer)" >&2; exit 1; }
_stg_probe mktemp "$_stg_outer"
_stg_root="$(cat "$STG/sig/root" 2>/dev/null)"
check "temp guard: the probe run reported its temp root" "sw-suite-" "$_stg_root"
check_absent "temp guard: a nested run's root is not inside the outer run's root" "$_stg_outer/" "$_stg_root/"
rm -rf "$_stg_outer"  # the outer run exits and removes its root
check "temp guard: the nested run keeps its root when the outer root is removed" "kept" "$([[ -n "$_stg_root" && -d "$_stg_root" ]] && echo kept)"
[[ -n "$_stg_root" && "$_stg_root" == */sw-suite-* ]] && rm -rf "$_stg_root"  # now its own root vanishes
touch "$STG/sig/go"
wait "$_stg_pid"
_stg_log="$(cat "$STG/probe-mktemp.log" 2>/dev/null)"
check "temp guard: a failed mktemp stops the run with an error" "FATAL: mktemp" "$_stg_log"
check_absent "temp guard: nothing after the failed mktemp ran" "x" "$([[ -e "$STG/sig/finished" ]] && echo x)"
check_absent "temp guard: the stopped run did not exit 0" "rc=0" "rc=$(cat "$STG/sig/rc" 2>/dev/null)"
check "temp guard: the checkout and its origin are untouched after the root vanished" "same" "$([[ "$(_stg_snap)" == "$_stg_before" ]] && echo same)"

# --- 2. an empty path handed straight to git and cd (no mktemp involved)
_stg_outer="$(mktemp -d)"
[[ -n "$_stg_outer" && -d "$_stg_outer" ]] || { echo "FATAL: mktemp -d failed (suite-temp-guard outer 2)" >&2; exit 1; }
_stg_probe empty "$_stg_outer"
touch "$STG/sig/go"
wait "$_stg_pid"
_stg_log="$(cat "$STG/probe-empty.log" 2>/dev/null)"
check "temp guard: git refuses to write outside the run's temp root" "git-guard: refusing" "$_stg_log"
check "temp guard: cd to an empty path is refused, never the current directory" "FATAL: cd to an empty path" "$_stg_log"
check_absent "temp guard: nothing after the refused cd ran" "x" "$([[ -e "$STG/sig/finished" ]] && echo x)"
check "temp guard: the checkout and its origin are untouched by empty-path git (bash and python)" "same" "$([[ "$(_stg_snap)" == "$_stg_before" ]] && echo same)"
rm -rf "$_stg_outer" "$STG"
