#!/usr/bin/env bash
# section-ui-hub.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== ui-hub (lifecycle on a scratch port) =="
_hubtmp="$(mktemp -d)"
export UI_HUB_STATE="$_hubtmp/hub"
HUB="$PLUGIN/scripts/ui-hub.py"
lifecycle_start "hub starts" UI_HUB_PORT 'python3 "$HUB" start'
echo '<h1>d</h1>' > "$UI_HUB_STATE/d.html"
out="$(python3 "$HUB" ask d1 "T" "$UI_HUB_STATE/d.html" --blocking)"; check "hub ask" "asked 'd1'" "$out"
out="$(curl -sf "http://127.0.0.1:$UI_HUB_PORT/api/state")";    check "hub state has pending" '"id": "d1"' "$out"
out="$(curl -sf -X POST "http://127.0.0.1:$UI_HUB_PORT/api/answer" -H 'Content-Type: application/json' -d '{"id":"d1","selection":"- Use: Option A"}')"
check "hub answer accepted" '"ok": true' "$out"
out="$(python3 "$HUB" answers --consume)";            check "hub answer collected" "Use: Option A" "$out"
out="$(python3 "$HUB" answers)";                      check_absent "hub consume archived it" "d1" "$out"

# #55: start must FAIL loudly when the port it's asked to bind is already
# held by someone else -- otherwise a caller whose own server never came
# up keeps reporting RUNNING and its clients silently talk to whichever
# process DID bind that port (see _rand_port's check-then-bind window:
# two concurrent callers can both probe the same free port microseconds
# apart and both pick it), so answers/consumes land in the wrong state
# dir instead of failing visibly. Force the collision directly -- this
# suite's own hub above is still bound to $UI_HUB_PORT -- rather than
# rely on timing luck to hit the same race.
_collide_dir="$(mktemp -d)/hub"
out="$(UI_HUB_STATE="$_collide_dir" python3 "$HUB" start --port "$UI_HUB_PORT" 2>&1)"
check_rc "hub start reports failure on an already-bound port" 1 "$?"
rm -rf "$(dirname "$_collide_dir")"

out="$(python3 "$HUB" stop)"; check "hub stop confirms exit (normal path)" "stopped" "$out"
out="$(python3 "$HUB" status)"; check "hub status shows STOPPED after confirmed exit" "STOPPED" "$out"

# #98: stop must poll for actual process exit after SIGTERM and only claim
# "stopped" once it's confirmed gone -- printing it unconditionally is the
# same premature-success-declaration class as #55's start bug. Prove it
# against a process that IGNORES SIGTERM (a detached target that won't die
# politely), so a truthful non-zero failure is the only correct behavior.
_ignoretmp="$(mktemp -d)/hub"
mkdir -p "$_ignoretmp"
UI_HUB_STATE="$_ignoretmp" python3 -c '
import os, signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(os.environ["UI_HUB_STATE"] + "/pid", "w") as f:
    f.write(str(os.getpid()))
time.sleep(30)
' &
_ignore_pid=$!
for _ in $(seq 1 30); do [[ -s "$_ignoretmp/pid" ]] && break; sleep 0.1; done
out="$(UI_HUB_STATE="$_ignoretmp" python3 "$HUB" stop 2>&1)"; rc=$?
check "hub stop is truthful when target ignores SIGTERM" "still running after SIGTERM" "$out"
check_rc "hub stop exits non-zero when target survives SIGTERM" 1 "$rc"
kill -9 "$_ignore_pid" 2>/dev/null
wait "$_ignore_pid" 2>/dev/null
rm -rf "$(dirname "$_ignoretmp")"

unset UI_HUB_STATE UI_HUB_PORT

