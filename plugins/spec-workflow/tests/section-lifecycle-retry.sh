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

