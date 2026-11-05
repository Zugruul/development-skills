#!/usr/bin/env bash
# section-project-items.sh -- sourced by run-tests.sh; do not run standalone.
# #544: slim GraphQL board read (project_items.py), unit-tested in Python.
# Real-capture fixtures used by test_project_items.py: gh-failures/graphql-items-page-live.txt and
# gh-failures/graphql-rate-limit-payload.txt, gh-failures/graphql-fields-live.txt (see their provenance headers).
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== project_items.py: slim board-read query + gh item-list shape (#544) =="
_pi_out="$(python3 "$HERE/test_project_items.py" 2>&1)"; _pi_rc=$?
if [[ "$_pi_rc" -eq 0 ]]; then
    echo "ok   test_project_items.py passes"
else
    echo "$_pi_out"; echo "FAIL test_project_items.py"; fails=$((fails + 1))
fi
check "README: Retry-After takes precedence over X-Ratelimit-Reset" "Retry-After" "$(sed -n '/^## Board reads: slim GraphQL query/,/^## /p' "$PLUGIN/README.md")"
_readme_544="$(sed -n '/^## Board reads: slim GraphQL query/,/^## WIP admission/p' "$PLUGIN/README.md")"
_readme_rl="$(grep -F 'rate-limit resilience' "$PLUGIN/README.md")"
check "README rate-limit text: reset comes from the rejected response's headers first" "reset from the rejected response's headers, falling back to \`gh api rate_limit\`" "$_readme_rl"
check_absent "README rate-limit text: no longer claims the reset comes from gh api rate_limit alone" "(reset from \`gh api rate_limit\`, works" "$_readme_rl"
check "README rate-limit text: RATE_LIMIT / graphql_rate_limit payloads are matched without a probe" "graphql_rate_limit" "$_readme_rl"
check "README #544: add on a non-rate-limit read failure prints DEFERRED, keeps the op, exits nonzero (a stop)" "DEFERRED" "$_readme_544"
check "README #544: the DEFERRED contract says nonzero" "exits nonzero" "$_readme_544"
check "README #544: strict reads fail closed with WIP BLOCKED on a missing Status field" "WIP BLOCKED" "$_readme_544"
check "README #544: an ambiguous Status field is covered" "ambiguous" "$_readme_544"
check "README #544: other reads warn on a missing Status" "warn" "$_readme_544"
