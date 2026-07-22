#!/usr/bin/env bash
# section-assistant-gates.sh -- AST-017: E1 numeric gates harness, stub mode
# (SPEC-ASSISTANT.md Sec15 N1-N5, issue #315, the E2 unblock). Sourced by
# run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== assistant gates (AST-017: Sec15 N1-N5 harness, stub mode proves the plumbing) =="

AG_SCRIPTS="$PLUGIN/scripts"
AG_GATES="$AG_SCRIPTS/assistant/gates.py"
AG_TMPPY="$(mktemp -d)"

# ---------------------------------------------------------- unit: percentile/variance math
echo "-- unit: percentile/variance helpers on known input --"
cat >"$AG_TMPPY/stats.py" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from assistant import gates

# 1..10: nearest-rank p50 = ceil(0.5*10)=5th smallest = 5; p95 = ceil(0.95*10)=10th = 10
data = list(range(1, 11))
print("P50", gates._percentile(data, 50))
print("P95", gates._percentile(data, 95))
print("VARIANCE_ZERO_FOR_CONSTANT", gates._stats([7, 7, 7])["variance"])
print("SINGLE_SAMPLE_STATS", gates._stats([42.0]))
print("EMPTY_STATS", gates._stats([]))
PYEOF
out="$(python3 "$AG_TMPPY/stats.py" "$AG_SCRIPTS" 2>&1)"
check "percentile: p50 of 1..10 is nearest-rank 5" "P50 5" "$out"
check "percentile: p95 of 1..10 is nearest-rank 10" "P95 10" "$out"
check "variance: constant samples have zero variance" "VARIANCE_ZERO_FOR_CONSTANT 0" "$out"
check "stats: a single sample is its own p50/p95/mean, variance 0.0" \
    "SINGLE_SAMPLE_STATS {'n': 1, 'p50': 42.0, 'p95': 42.0, 'variance': 0.0, 'mean': 42.0}" "$out"
check "stats: empty samples degrade to all-None, n=0 (never raises)" \
    "EMPTY_STATS {'n': 0, 'p50': None, 'p95': None, 'variance': None, 'mean': None}" "$out"

# ---------------------------------------------------------- unit: Sec15 threshold constants (defaults-need-own-tests)
echo "-- unit: Sec15 threshold constants match the spec's literal numbers --"
gates_src="$(cat "$AG_GATES")"
check "N1 threshold: p95 <= 15.0s (Sec15 'p95 <= 15s or E2 is blocked')" "N1_P95_MAX_SECONDS = 15.0" "$gates_src"
check "N2 threshold: recall p95 < 300.0ms (Sec15 'incl. embedding hop < 300ms')" "N2_P95_MAX_MS = 300.0" "$gates_src"
check "N3 threshold: documented degradation-factor constant exists" "N3_DEGRADATION_FACTOR_MAX = 3.0" "$gates_src"
check "N5 threshold: documented timeout-margin constant exists" "N5_TIMEOUT_MARGIN_SECONDS = 5.0" "$gates_src"

# ---------------------------------------------------------- unit: CLI argument errors
echo "-- unit: unknown --gates name is a clean usage error, not a crash --"
unknown_out="$(python3 "$AG_GATES" --mode stub --gates BOGUS --out "$AG_TMPPY/unknown.json" 2>&1)"
unknown_rc=$?
check_rc "unknown --gates name: exits 2 (argparse usage error)" 2 "$unknown_rc"
check "unknown --gates name: names the bad gate and the valid set" "unknown gate(s): BOGUS (valid: N1, N2, N3, N4, N5)" "$unknown_out"
check_absent "unknown --gates name: no raw traceback" "Traceback" "$unknown_out"

# ---------------------------------------------------------- unit: --gates subset filter
echo "-- unit: --gates N5 runs only N5 --"
python3 "$AG_GATES" --mode stub --gates N5 --out "$AG_TMPPY/n5-only.json" --ts 2026-07-22T00:00:00Z >/dev/null
n5_only_rc=$?
check_rc "gates subset: --gates N5 exits 0" 0 "$n5_only_rc"
n5_only_body="$(cat "$AG_TMPPY/n5-only.json")"
check "gates subset: N5 key present" '"N5"' "$n5_only_body"
check_absent "gates subset: N1 key absent (not requested)" '"N1"' "$n5_only_body"
check_absent "gates subset: N2 key absent (not requested)" '"N2"' "$n5_only_body"

# ---------------------------------------------------------- integration: full stub-mode run, all five gates
echo "-- integration: full --mode stub run, all five Sec15 gates, results recorded --"
ag_out="$AG_TMPPY/full.json"
full_stdout="$(python3 "$AG_GATES" --mode stub --out "$ag_out" --ts 2026-07-22T00:00:00Z 2>&1)"
full_rc=$?
check_rc "full stub run: exits 0 (every gate passes in stub mode)" 0 "$full_rc"
check "full stub run: N1 prints PASS" "N1: PASS" "$full_stdout"
check "full stub run: N2 prints PASS" "N2: PASS" "$full_stdout"
check "full stub run: N3 prints PASS" "N3: PASS" "$full_stdout"
check "full stub run: N4 prints PASS" "N4: PASS" "$full_stdout"
check "full stub run: N5 prints PASS" "N5: PASS" "$full_stdout"
check "full stub run: reports the written path" "wrote $ag_out" "$full_stdout"

ag_body="$(cat "$ag_out")"
check "results JSON: mode is stub" '"mode": "stub"' "$ag_body"
check "results JSON: ts is the injected value (no bare Date.now in a tested path)" '"ts": "2026-07-22T00:00:00Z"' "$ag_body"

# N1: 20-turn session, p95 threshold, tool-use-rate proof
check "N1: drives the full spec-literal 20 turns" '"n_turns": 20' "$ag_body"
check "N1: passed true (p95 well under 15s against the stub)" '"gate": "N1"' "$ag_body"
n1_json="$(python3 -c "import json; print(json.dumps(json.load(open('$ag_out'))['gates']['N1']))")"
check "N1: passed" '"passed": true' "$n1_json"
check "N1: tool_use_rate is exactly 1/20 (the one scripted turn fired a tool event)" '"tool_use_rate": 0.05' "$n1_json"
check "N1: records the threshold it graded against" '"threshold_p95_seconds": 15.0' "$n1_json"
check "N1: records p50/p95/variance (results recorded, not just a verdict)" '"p95_seconds"' "$n1_json"
check "N1: real-mode-only tool_use_note is null in stub mode" '"tool_use_note": null' "$n1_json"

# N2: recall p95 incl. embedding hop, with cache
n2_json="$(python3 -c "import json; print(json.dumps(json.load(open('$ag_out'))['gates']['N2']))")"
check "N2: passed" '"passed": true' "$n2_json"
check "N2: records the threshold it graded against" '"threshold_p95_ms": 300.0' "$n2_json"
check "N2: exercises the query-embed cache (hit rate present, results recorded)" '"cache_hit_rate"' "$n2_json"
# review r1: with cycled stub queries the hit path genuinely fires -- 3 distinct
# queries over 30 samples means 27 hits; assert a nonzero rate, not just presence.
n2_hit_nonzero="$(python3 -c "import json; print(json.load(open('$ag_out'))['gates']['N2']['cache_hit_rate'] > 0)" 2>/dev/null || echo probe-failed)"
check "N2: stub cache hit rate is genuinely nonzero (hit path exercised)" "True" "$n2_hit_nonzero"
check "N2: default n_samples is 30" '"n_samples": 30' "$n2_json"

# N3: page-isolation
n3_json="$(python3 -c "import json; print(json.dumps(json.load(open('$ag_out'))['gates']['N3']))")"
check "N3: passed" '"passed": true' "$n3_json"
check "N3: records baseline and loaded p95 (results recorded)" '"baseline_p95_seconds"' "$n3_json"
check "N3: records the degradation factor against its threshold" '"degradation_factor"' "$n3_json"
check "N3: confirms /graph was actually polled during the load window" '"graph_poll_count_during_load"' "$n3_json"

# N4: kill -9 mid-turn recovery
n4_json="$(python3 -c "import json; print(json.dumps(json.load(open('$ag_out'))['gates']['N4']))")"
check "N4: passed" '"passed": true' "$n4_json"
check "N4: the marker-barrier saw the turn start before the kill" '"marker_seen_before_kill": true' "$n4_json"
check "N4: the pre-kill exchange succeeded (something concrete to resume)" '"pre_kill_exchange_ok": true' "$n4_json"
check "N4: history survived the restart with the pre-kill exchange intact" '"history_intact_after_restart": true' "$n4_json"
check "N4: session-state.json parses after restart" '"session_state_parses": true' "$n4_json"
check "N4: session.jsonl parses with no torn-line warnings (kill landed before any append)" \
    '"session_jsonl_parses_no_warnings": true' "$n4_json"
check "N4: links.json parses or is absent (never corrupted)" '"links_json_parses_or_absent": true' "$n4_json"

# N5: logged-out provider, bounded + specific
n5_json="$(python3 -c "import json; print(json.dumps(json.load(open('$ag_out'))['gates']['N5']))")"
check "N5: passed" '"passed": true' "$n5_json"
check "N5: bounded (well inside the timeout+margin bound)" '"bounded": true' "$n5_json"
check "N5: specific (error message names the login instruction)" '"specific": true' "$n5_json"
check "N5: HTTP 502 (upstream provider failure, never a 500 crash)" '"http_status": 502' "$n5_json"
check "N5: error message instructs codex login" "codex login" "$n5_json"

rm -rf "$AG_TMPPY"

# --- review r2 blockers: regression checks ------------------------------------
# (1) a crashing gate records partial results + incomplete marker, never
# discards completed gates; (2) unwritable --out is a clean one-line error.
ag_r2_out="$(PYTHONPATH="$AG_SCRIPTS" python3 - "$AG_TMPPY" <<'PY'
import json, sys
from assistant import gates
# run_gates executes in N1..N5 order regardless of request order, so the
# crashing gate must sort AFTER the completed one: N3 completes, N5 crashes.
orig = gates.run_n5
def boom(*a, **k):
    raise RuntimeError("forced n5 crash")
gates.run_n5 = boom
try:
    r = gates.run_gates("stub", ["N3", "N5"], ts="2026-07-22T00:00:00Z")
finally:
    gates.run_n5 = orig
print("PARTIAL_HAS_N5", "N3" in r["gates"] and r["gates"]["N3"].get("passed") is True)
print("CRASHED_GATE_RECORDED", r["gates"].get("N5", {}).get("error", "").startswith("RuntimeError"))
print("MARKED_INCOMPLETE", r.get("incomplete") is True)
PY
)"
ag_r2_rc=$?
check_rc "r2: partial-results probe runs" 0 "$ag_r2_rc"
check "r2: completed gates survive a later crash" "PARTIAL_HAS_N5 True" "$ag_r2_out"
check "r2: crashed gate recorded with its error" "CRASHED_GATE_RECORDED True" "$ag_r2_out"
check "r2: results marked incomplete on crash" "MARKED_INCOMPLETE True" "$ag_r2_out"

ag_r2b_out="$(PYTHONPATH="$AG_SCRIPTS" python3 "$AG_GATES" --mode stub --gates N5 --out /nonexistent-root-dir-ast017/out.json --ts 2026-07-22T00:00:00Z 2>&1)"
ag_r2b_rc=$?
check_rc "r2: unwritable --out exits 2" 2 "$ag_r2b_rc"
check "r2: unwritable --out yields a clean one-line error" "cannot write --out" "$ag_r2b_out"
check_absent "r2: unwritable --out leaks no traceback" "Traceback (most recent call last)" "$ag_r2b_out"
