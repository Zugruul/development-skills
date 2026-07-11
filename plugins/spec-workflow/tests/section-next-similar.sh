#!/usr/bin/env bash
# section-next-similar.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== next.py (picker) =="
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.json" "" "$FIX/items.sample.json")"
check "bug preempts features" "=> PICK: #99" "$out"
check "guard blocks E1" "BLOCKED #10 FX-010: link endpoint  (epic E0 not fully Deployed)" "$out"
check "P0 candidate listed" "#2  [P0]  FX-002" "$out"
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.json" "" "$FIX/items.wip.json")"
check "wip resume guard" "=> RESUME: #2  FX-002: auth model" "$out"
check_absent "wip: no new pick" "=> PICK:" "$out"

# SW-012: blocking epic with zero seeded tasks gets a distinct, actionable message
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.json" "" "$FIX/items.unseeded.json")"
check "unseeded epic: distinct message" "epic E9 unseeded — run seed-board" "$out"
check_absent "unseeded epic: fail-closed (no pick)" "=> PICK:" "$out"
check_absent "unseeded epic: not the misleading not-fully message" "not fully" "$out"

# regression: blocking epic has seeded tasks but not all at required status -> existing message unchanged
check_absent "seeded-but-unmet: no unseeded message" "unseeded — run seed-board" "$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.json" "" "$FIX/items.sample.json")"

# regression: blocking epic satisfied -> downstream candidate is picked, no blocked message
out="$(python3 "$PLUGIN/scripts/next.py" "$FIX/valid.project.json" "" "$FIX/items.satisfied.json")"
check "satisfied epic: downstream candidate picked" "=> PICK: #20" "$out"
check_absent "satisfied epic: no unseeded message" "unseeded — run seed-board" "$out"
check_absent "satisfied epic: no blocked entry" "BLOCKED #20" "$out"

echo "== similar.py (dedup/similarity) =="
SIM="$PLUGIN/scripts/similar.py"
export SIMILAR_ISSUES_FILE="$FIX/issues.sample.json"

out="$(python3 "$SIM" "$HERE" "Add dark mode toggle to settings page")"
first_line="$(head -1 <<<"$out")"
check "exact title match: #21 is top-ranked" "#21" "$first_line"
check "exact title match: high tier" "high" "$first_line"

out="$(python3 "$SIM" "$HERE" "I want to add a dark theme toggle option on the settings screen")"
first_line="$(head -1 <<<"$out")"
check "paraphrase match: #21 is top-ranked" "#21" "$first_line"
check_absent "paraphrase match: not low tier" $'low\t' "$first_line"
unrelated="$(grep -E '#22|#23' <<<"$out" || true)"
check_absent "paraphrase match: unrelated issues not high tier" $'high\t' "$unrelated"
check_absent "paraphrase match: unrelated issues not medium tier" $'medium\t' "$unrelated"

out="$(python3 "$SIM" "$HERE" "refactor database connection pooling for performance"; echo "rc=$?")"
check "no-match query: exits 0" "rc=0" "$out"
check_absent "no-match query: no high tier" $'high\t' "$out"
check_absent "no-match query: no medium tier" $'medium\t' "$out"

export SIMILAR_ISSUES_FILE="$FIX/issues.control-chars.json"
out="$(python3 "$SIM" "$HERE" "weird title with control chars")"
lines="$(wc -l <<<"$out" | tr -d ' ')"
check "control chars in title: single-line output" "1" "$lines"
fields="$(awk -F'\t' '{print NF; exit}' <<<"$out")"
check "control chars in title: 5 tab-separated fields" "5" "$fields"

unset SIMILAR_ISSUES_FILE

