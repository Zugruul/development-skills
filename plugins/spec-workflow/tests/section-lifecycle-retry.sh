#!/usr/bin/env bash
# section-lifecycle-retry.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
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

