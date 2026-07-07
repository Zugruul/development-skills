#!/usr/bin/env bash
# section-ui-hub.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
# shellcheck disable=SC2016  # lifecycle_start command-strings are single-quoted on
# purpose -- they're expanded when eval'd inside the function, not at call site.
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
python3 "$HUB" stop >/dev/null
unset UI_HUB_STATE UI_HUB_PORT

