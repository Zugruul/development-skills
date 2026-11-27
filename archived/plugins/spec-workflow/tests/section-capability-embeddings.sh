#!/usr/bin/env bash
# section-capability-embeddings.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# MEM-030 (§9.1/§9.1.1, OQ-2/OQ-4): the embeddings capability install.
# Two tiers of coverage live here:
#   * FAST (always run, hermetic, no network): capability.sh's contract when
#     the capability is absent or its venv is broken -- the §9.1.1 graceful-
#     absence signal a future recall consumer (MEM-032) relies on. The broken-
#     venv case builds a REAL venv (python3 -m venv, no network) that simply
#     lacks onnxruntime, proving the healthcheck catches a genuinely broken
#     install, not merely a missing directory.
#   * SLOW (RUN_SLOW_TESTS=1 only): a real install -- pip-installs pinned
#     onnxruntime/tokenizers/numpy and downloads the pinned ONNX model, then
#     asserts healthcheck-healthy, a 384-dim embed round-trip, and an
#     idempotent+offline second install. These make real network requests and
#     take real wall-clock time, so the DEFAULT gate run skips them (there is
#     no prior slow-test precedent in this suite; RUN_SLOW_TESTS is introduced
#     here and documented in the section header + capability.sh).
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }

CAP="$PLUGIN/scripts/capability.sh"

echo "== capability.sh: script contract (#138) =="
check "capability.sh exists" "OK" "$(test -f "$CAP" && echo OK)"
check_rc "capability.sh is valid bash" 0 "$(bash -n "$CAP" >/dev/null 2>&1; echo $?)"

# no args / unknown subcommand -> usage error (exit 2), never a stack trace.
out="$(bash "$CAP" 2>&1)"; rc=$?
check_rc "capability.sh no args exits 2" 2 "$rc"
check "capability.sh no args prints usage" "usage" "$out"

out="$(bash "$CAP" install bogus-capability 2>&1)"; rc=$?
check_rc "install unknown capability exits 2" 2 "$rc"
check "install unknown capability names it" "bogus-capability" "$out"

echo "== capability.sh: graceful absence -- not installed (§9.1.1) =="
# A clean dir with nothing in it: healthcheck must report NOT INSTALLED and
# exit 3 (the "unavailable" signal), printing at most one notice line and
# nothing to stdout.
ABSENT="$(mktemp -d)"
out="$(bash "$CAP" healthcheck embeddings --dir "$ABSENT/embeddings" 2>/dev/null)"; rc=$?
err="$(bash "$CAP" healthcheck embeddings --dir "$ABSENT/embeddings" 2>&1 1>/dev/null)"
check_rc "healthcheck absent exits 3 (unavailable)" 3 "$rc"
check "healthcheck absent stdout empty" "" "$out"
check "healthcheck absent notice says not installed" "not installed" "$err"
nlines="$(printf '%s' "$err" | grep -c .)"
check "healthcheck absent prints at most one notice line" "1" "$nlines"
rm -rf "$ABSENT"

echo "== capability.sh: healthcheck detects a broken venv (§9.1) =="
# Genuinely broken: a REAL venv (no network) that lacks onnxruntime, plus a
# manifest and model dir, so this is NOT the "missing directory" case -- the
# healthcheck must import-probe the venv to catch it, and must report BROKEN
# distinctly from NOT INSTALLED.
BROKEN="$(mktemp -d)"
BDIR="$BROKEN/embeddings"
mkdir -p "$BDIR/model"
python3 -m venv "$BDIR/venv" >/dev/null 2>&1
: >"$BDIR/model/model.onnx"
: >"$BDIR/model/tokenizer.json"
printf '{"name":"embeddings","version":"broken-fixture"}\n' >"$BDIR/manifest.json"
berr="$(bash "$CAP" healthcheck embeddings --dir "$BDIR" 2>&1 1>/dev/null)"; brc=$?
check_rc "healthcheck broken venv exits 3 (unavailable)" 3 "$brc"
check "healthcheck broken venv reports broken/unhealthy" "unhealthy" "$berr"
check_absent "healthcheck broken venv NOT reported as 'not installed'" "not installed" "$berr"
bnlines="$(printf '%s' "$berr" | grep -c .)"
check "healthcheck broken venv prints at most one notice line" "1" "$bnlines"
rm -rf "$BROKEN"

echo "== capability.sh: recall graceful-absence regression (§9.1.1) =="
# Written when MEM-030 predated any recall wiring, this originally asserted
# brain.py NEVER mentions the capability. AST-018 (merged 2026-07-22) then
# legitimately wired embeddings-capability recall into brain.py — with §9.1.1
# graceful absence. The meaningful invariant now: brain.py reaches the
# capability ONLY through capability.sh (never inlining venv/model paths),
# and recall still functions with no capability installed (next check).
check "brain.py reaches embeddings only via capability.sh (single integration point)" "capability.sh" "$(cat "$PLUGIN/scripts/brain.py")"
check_absent "brain.py never hardcodes the capability venv location" ".claude/capabilities" "$(cat "$PLUGIN/scripts/brain.py")"
RB="$(mktemp -d)"
printf 'Recall works with no embeddings capability installed.\n' \
    | python3 "$PLUGIN/scripts/brain.py" "$RB" mint dev embed-absent \
        --tags retrieval --paths "plugins/**" --source "fixture" >/dev/null 2>&1
rout="$(python3 "$PLUGIN/scripts/brain.py" "$RB" recall dev --paths "plugins/x.sh" --keywords "" 2>&1)"
check "recall works with no capability present" "embed-absent" "$rout"
rm -rf "$RB"

# --- SLOW: real install (network + wall-clock), opt-in via RUN_SLOW_TESTS ---
if [[ "${RUN_SLOW_TESTS:-}" != "1" ]]; then
    echo "== capability.sh: real-install tests SKIPPED (set RUN_SLOW_TESTS=1 to run) =="
else
    echo "== capability.sh: real install (RUN_SLOW_TESTS=1) =="
    SLOW="$(mktemp -d)"
    SDIR="$SLOW/embeddings"
    bash "$CAP" install embeddings --dir "$SDIR" >/dev/null 2>&1; irc=$?
    check_rc "install embeddings exits 0" 0 "$irc"
    check "install creates manifest.json" "OK" "$(test -f "$SDIR/manifest.json" && echo OK)"
    check "install creates venv python" "OK" "$(test -x "$SDIR/venv/bin/python" && echo OK)"
    check "install downloads model.onnx" "OK" "$(test -s "$SDIR/model/model.onnx" && echo OK)"

    man="$(cat "$SDIR/manifest.json" 2>&1)"
    check "manifest name is embeddings" "\"name\": \"embeddings\"" "$man"
    check "manifest pins model revision" "ea104dacec62c0de699686887e3f920caeb4f3e3" "$man"
    check "manifest records 384 dim" "384" "$man"

    bash "$CAP" healthcheck embeddings --dir "$SDIR" >/dev/null 2>&1; hrc=$?
    check_rc "healthcheck healthy exits 0" 0 "$hrc"

    # embed round-trip: 2 input lines -> 2 output JSON arrays, each 384-dim.
    eout="$(printf 'hello world\nvector search\n' | bash "$CAP" embed embeddings --dir "$SDIR" 2>/dev/null)"
    elines="$(printf '%s\n' "$eout" | grep -c .)"
    check "embed emits one line per input" "2" "$elines"
    dim1="$(printf '%s\n' "$eout" | sed -n '1p' | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())))' 2>&1)"
    check "embed vector is pinned 384-dim" "384" "$dim1"

    # empty/whitespace-only line still yields exactly one 384-dim array.
    zout="$(printf '   \n' | bash "$CAP" embed embeddings --dir "$SDIR" 2>/dev/null)"
    zdim="$(printf '%s\n' "$zout" | sed -n '1p' | python3 -c 'import json,sys; print(len(json.loads(sys.stdin.read())))' 2>&1)"
    check "embed empty line yields a 384-dim vector" "384" "$zdim"

    # idempotent + offline: second install must not re-download the model
    # (mtime unchanged) and must report a skip, quickly.
    before="$(stat -f %m "$SDIR/model/model.onnx" 2>/dev/null || stat -c %Y "$SDIR/model/model.onnx")"
    iout2="$(bash "$CAP" install embeddings --dir "$SDIR" 2>&1)"; irc2=$?
    after="$(stat -f %m "$SDIR/model/model.onnx" 2>/dev/null || stat -c %Y "$SDIR/model/model.onnx")"
    check_rc "second install exits 0" 0 "$irc2"
    check "second install skips (already installed)" "already installed" "$iout2"
    check "second install does not re-download model (mtime stable)" "$before" "$after"

    rm -rf "$SLOW"
fi
