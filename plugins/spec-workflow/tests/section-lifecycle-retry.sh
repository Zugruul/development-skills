#!/usr/bin/env bash
# section-lifecycle-retry.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== server-lifecycle retry-once (SW-014, SPEC 7.5) =="
# Meta-test: a deliberately-flaky command (fails once, then succeeds) proves
# lifecycle_start()'s 3-state logic -- ok / FLAKY (passed on retry) / FAIL --
# ahead of wiring it into the real neural-view/ui-hub sections below.
_lcflag="$(mktemp)"; : >"$_lcflag"   # empty = not yet attempted
_lc_flaky_cmd() {
    if [[ -s "$_lcflag" ]]; then
        echo "RUNNING http://127.0.0.1:$LC_TEST_PORT"
    else
        echo attempted >"$_lcflag"
        echo "boom: connection refused"
    fi
}
export -f _lc_flaky_cmd
lcout="$(lifecycle_start "meta: flaky-once command reports FLAKY on retry" LC_TEST_PORT '_lc_flaky_cmd' 2>&1)"
check "meta: flaky-once command is reported FLAKY, not a plain ok/FAIL" "FLAKY meta: flaky-once command reports FLAKY on retry (passed on retry)" "$lcout"

_lc_always_fails() { echo "boom: connection refused"; }
export -f _lc_always_fails
lcout2="$(lifecycle_start "meta: always-failing command still FAILs" LC_TEST_PORT2 '_lc_always_fails' 2>&1)"
check "meta: a command that fails twice still reports a real FAIL" "FAIL meta: always-failing command still FAILs" "$lcout2"

rm -f "$_lcflag"

# Anti-pattern check: the ui-hub lifecycle section must no longer hard-code
# its port (the fixed-port + no-retry combination is exactly what produced
# the collisions in issue #8 under concurrent lanes). Lives in its own
# section-ui-hub.sh file post-split; that's the file to inspect now.
check_absent "ui-hub lifecycle section no longer hard-codes UI_HUB_PORT=4799" "UI_HUB_PORT=4799" "$(cat "$HERE/section-ui-hub.sh")"

echo "== _rand_port cross-suite port isolation (development-skills#97) =="
# development-skills#97: under CONCURRENT full-suite runs, one suite's
# _rand_port() pick can land on the exact port another suite's _rand_port()
# also picked -- each process's "is it free" check (and its _used_ports
# de-dup list) only ever sees its OWN draws, never the other suite's. A
# forced-collision reproduction: two separate bash PROCESSES (real distinct
# PIDs, like two concurrent run-tests.sh runs) with $RANDOM seeded
# IDENTICALLY represent the worst case -- same draws, same instant. Before
# #97, _rand_port() drew from the single shared 20000-39999 band with no
# other entropy than $RANDOM, so identically-seeded processes picked the
# IDENTICAL port every time: not a maybe, a guaranteed repro. After #97,
# each process's draw is also floored by its own PID's disjoint slice, so
# identical $RANDOM streams land in different bands unless the two PIDs
# happen to be congruent mod the slice count (two processes alive at the
# same instant essentially never share a PID mod 200).
_p1="$(bash -c 'source "$1/_lib.sh"; RANDOM=42; _rand_port' _ "$HERE")"
_p2="$(bash -c 'source "$1/_lib.sh"; RANDOM=42; _rand_port' _ "$HERE")"
if [[ "$_p1" == "$_p2" ]]; then
    echo "FAIL cross-suite: two suites with identical \$RANDOM streams picked the same port ($_p1) -- development-skills#97"
    fails=$((fails + 1))
else
    echo "ok   cross-suite: two suites with identical \$RANDOM streams pick disjoint ports ($_p1 vs $_p2)"
fi

# Same property, restated as a pure/deterministic unit check on the
# PID->band mapping itself (no process spawns, no timing): adjacent PIDs
# must land in different bands, and the mapping must be a pure function of
# the pid (same pid in, same band out, every time) -- this is what makes the
# process-spawn check above reliable rather than a lucky draw.
_b1="$(_port_base 100000)"; _b2="$(_port_base 100001)"
if [[ "$_b1" != "$_b2" ]]; then _b_differ_rc=0; else _b_differ_rc=1; fi
check_rc "PID->band mapping: adjacent pids land in different bands" 0 "$_b_differ_rc"
_b3="$(_port_base 100000)"
check "PID->band mapping: pure function of pid (repeatable)" "$_b1" "$_b3"

echo "== _rand_port excludes an unbound sibling port across command substitutions =="
# Each substitution inherits the same empty _used_ports, as in the metrics
# fixture. Seed inside each child so the duplicate first draw is deterministic.
_excluded_out="$(bash -c '
    source "$1/_lib.sh"
    first="$(RANDOM=42; _rand_port)"
    repeated="$(RANDOM=42; _rand_port)"
    [[ "$first" == "$repeated" ]] || exit 2
    echo "repeated draw confirmed"
    second="$(RANDOM=42; _rand_port "$first")" || exit 3
    [[ "$first" != "$second" ]]
' _ "$HERE" 2>&1)"
_excluded_rc=$?
check "port exclusion fixture: same seed reproduces the sibling collision" "repeated draw confirmed" "$_excluded_out"
check_rc "port exclusion: explicit sibling survives command-substitution isolation" 0 "$_excluded_rc"

# One candidate forces every bounded attempt to hit the exclusion. Even the
# busy-port fallback must fail rather than return that port or loop forever.
# shellcheck disable=SC2016 # Match literal command syntax, never expand it.
check_absent "port exhaustion probe does not require GNU timeout" '$(''timeout ' "$(cat "$HERE/section-lifecycle-retry.sh")"
_exhausted_out="$(python3 - "$HERE" 2>&1 <<'PY'
import subprocess
import sys

script = r'''
    source "$1/_lib.sh"
    _PORT_SLICE_WIDTH=1
    _rand_port "$(_port_base)"
'''
try:
    result = subprocess.run(["bash", "-c", script, "_", sys.argv[1]],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=5)
except subprocess.TimeoutExpired:
    print("port helper exceeded the five-second bound", file=sys.stderr)
    sys.exit(124)
sys.stdout.write(result.stdout)
sys.exit(result.returncode)
PY
)"
_exhausted_rc=$?
check_rc "port exclusion: exhausted candidate set fails within the bound" 1 "$_exhausted_rc"
if [[ -z "$_exhausted_out" ]]; then _empty_port_rc=0; else _empty_port_rc=1; fi
check_rc "port exclusion: exhausted fallback emits no excluded port" 0 "$_empty_port_rc"

# #541: exercise the real selector/helper under identical draws, including
# the actual whisper call expressions. Replace only their server command in
# a subprocess; the caller arguments and helper selection still execute.
_lc541_out="$(python3 - "$HERE" 2>&1 <<'PY541'
from pathlib import Path
import shlex
import subprocess
import sys

here = Path(sys.argv[1])
setup = r"""
set -uo pipefail
source "$1/_lib.sh"
fails=0; flaky=0
lc541_definition="$(declare -f _rand_port)"
eval "${lc541_definition/_rand_port/lc541_real_rand}"
_rand_port() { RANDOM=42; lc541_real_rand "$@"; }
lc541_sibling="$(_rand_port)"
[[ "$lc541_sibling" == "$(_rand_port)" ]] || exit 20
lc541_calls="$(mktemp)"
trap "rm -f \"$lc541_calls\"" EXIT
lc541_command() {
    echo attempt >>"$lc541_calls"
    if [[ "$LC541_PORT" == "$lc541_sibling" ]]; then
        echo "collision: lifecycle reused the configured sibling"
    elif [[ "$(wc -l <"$lc541_calls")" -eq 1 ]]; then
        echo "synthetic first-start failure"
    else
        echo "RUNNING http://127.0.0.1:$LC541_PORT"
    fi
}
"""

def run(label, script, *args):
    try:
        result = subprocess.run(["bash", "-c", setup + script, "_", str(here), *args],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=5)
    except subprocess.TimeoutExpired:
        print("FAIL " + label + ": exceeded five-second bound")
        return False
    if result.returncode:
        print("FAIL " + label + ": " + result.stdout.strip())
        return False
    print("ok   " + label)
    return True

passed = run("lifecycle excludes sibling on both attempts and counts one flake", r"""
lifecycle_start seeded LC541_PORT lc541_command "$lc541_sibling"
lc541_rc=$?
echo "rc=$lc541_rc fails=$fails flaky=$flaky calls=$(wc -l <"$lc541_calls")"
[[ "$lc541_rc:$fails:$flaky" == "0:0:1" ]] &&
    [[ "$(wc -l <"$lc541_calls")" -eq 2 ]]
""")

passed = run("lifecycle exhaustion fails once without exporting or dispatching", r"""
_PORT_SLICE_WIDTH=1
lc541_sibling="$(_port_base)"
LC541_PORT=unchanged
lifecycle_start exhausted LC541_PORT lc541_command "$lc541_sibling"
lc541_rc=$?
echo "rc=$lc541_rc fails=$fails flaky=$flaky port=$LC541_PORT"
[[ "$lc541_rc:$fails:$flaky:$LC541_PORT" == "1:1:0:unchanged" ]] &&
    [[ ! -s "$lc541_calls" ]]
""") and passed

# Execute every current whisper lifecycle call, keeping all its arguments.
# Only substitute a synthetic server command after entering the wrapper;
# a missing fourth argument therefore exercises the old collision for real.
lines = (here / "section-whisper-sidecar.sh").read_text().splitlines()
calls = []
for index, line in enumerate(lines):
    if line.startswith("lifecycle_start "):
        command = line
        while command.endswith("\\"):
            index += 1
            command = command[:-1] + lines[index]
        calls.append(command)
if len(calls) != 5:
    print("FAIL whisper caller audit: expected five lifecycle invocations")
    passed = False
for call in calls:
    passed = run("whisper caller excludes configured sibling: " + shlex.split(call)[1], r"""
lc541_definition="$(declare -f lifecycle_start)"
eval "${lc541_definition/lifecycle_start/lc541_real_start}"
WS_NV_P_AUTO="$lc541_sibling"
WS_NV_P_FAIL="$lc541_sibling"
WS_NV_P_MISSING="$lc541_sibling"
lifecycle_start() {
    lc541_real_start "$1" LC541_PORT lc541_command "${4:-}"
}
eval "$2"
lc541_rc=$?
echo "rc=$lc541_rc fails=$fails flaky=$flaky"
[[ "$lc541_rc:$fails:$flaky" == "0:0:1" ]] &&
    [[ "$(wc -l <"$lc541_calls")" -eq 2 ]]
""", call) and passed
sys.exit(0 if passed else 1)
PY541
)"
_lc541_rc=$?
printf '%s\n' "$_lc541_out"
check_rc "lifecycle sibling exclusions, retry accounting and bounded exhaustion" 0 "$_lc541_rc"

# development-skills#97 item 3: with the fixture isolation above in place,
# re-verify the kill gate's PID/cmdline binding under a REAL concurrent
# collision -- two genuine neural-view servers, each its own "suite" (a
# separate bash process picking its own port via the now-isolated
# _rand_port()), running AT THE SAME TIME. One suite's `stop --force` must
# only ever act on whatever holds ITS OWN configured port; it must never
# reach across and kill the other suite's server. If ports come out equal
# here (the isolation regressed) this whole block would legitimately fail,
# which is the point: it's a live check of the isolation, not just a trust
# exercise in the gate's code.
NV="$PLUGIN/scripts/neural-view.py"
_s1root="$(mktemp -d)"; _s1state="$(mktemp -d)"
_s2root="$(mktemp -d)"; _s2state="$(mktemp -d)"
_s1port="$(bash -c 'source "$1/_lib.sh"; _rand_port' _ "$HERE")"
_s2port="$(bash -c 'source "$1/_lib.sh"; _rand_port' _ "$HERE")"
if [[ "$_s1port" == "$_s2port" ]]; then
    echo "FAIL cross-suite gate check: both simulated suites drew the same port ($_s1port) -- cannot exercise isolation"
    fails=$((fails + 1))
else
    NEURAL_VIEW_STATE="$_s1state" NEURAL_VIEW_PORT="$_s1port" python3 "$NV" start --dir "$_s1root" >/dev/null 2>&1
    NEURAL_VIEW_STATE="$_s2state" NEURAL_VIEW_PORT="$_s2port" python3 "$NV" start --dir "$_s2root" >/dev/null 2>&1
    _s1pid="$(cat "$_s1state/pid" 2>/dev/null || true)"
    _s2pid="$(cat "$_s2state/pid" 2>/dev/null || true)"
    if [[ -n "$_s1pid" ]]; then _s1up_rc=0; else _s1up_rc=1; fi
    if [[ -n "$_s2pid" ]]; then _s2up_rc=0; else _s2up_rc=1; fi
    check_rc "cross-suite gate check: suite 1 server came up" 0 "$_s1up_rc"
    check_rc "cross-suite gate check: suite 2 server came up" 0 "$_s2up_rc"
    NEURAL_VIEW_STATE="$_s1state" NEURAL_VIEW_PORT="$_s1port" python3 "$NV" stop --force >/dev/null 2>&1
    if kill -0 "$_s2pid" 2>/dev/null; then
        echo "ok   cross-suite gate check: suite 1's stop --force left suite 2's server alive"
    else
        echo "FAIL cross-suite gate check: suite 1's stop --force killed suite 2's UNRELATED server -- development-skills#97"
        fails=$((fails + 1))
    fi
    if ! kill -0 "$_s1pid" 2>/dev/null; then
        echo "ok   cross-suite gate check: suite 1's stop --force did kill its own server"
    else
        echo "FAIL cross-suite gate check: suite 1's stop --force left its OWN server running"
        fails=$((fails + 1))
    fi
    NEURAL_VIEW_STATE="$_s2state" NEURAL_VIEW_PORT="$_s2port" python3 "$NV" stop --force >/dev/null 2>&1
    kill "$_s1pid" "$_s2pid" 2>/dev/null || true
fi
rm -rf "$_s1root" "$_s1state" "$_s2root" "$_s2state"

