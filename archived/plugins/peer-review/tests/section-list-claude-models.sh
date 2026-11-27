#!/usr/bin/env bash
# section-list-claude-models.sh -- sourced by run-tests.sh; do not run
# standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent) and set HERE/PLUGIN/fails before
# sourcing this file.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/peer-review/tests/run-tests.sh" >&2; exit 2; }
echo "== list-claude-models.sh (CDX-054) =="

SCRIPT="$PLUGIN/scripts/list-claude-models.sh"

# list-claude-models.sh is a STATIC catalog -- unlike list-models.sh
# (codex), there is no live discovery call, so it must work identically
# with no `claude` binary anywhere on PATH and no network.
NOBIN="/usr/bin:/bin"

out="$(PATH="$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check "exits 0 with no claude on PATH" "rc=0" "$out"
check "recommended is claude-sonnet-5[1m]" '"recommended": "claude-sonnet-5[1m]"' "$out"
check "1m sonnet slug present" "claude-sonnet-5[1m]" "$out"
check "standard sonnet slug present" '"slug": "claude-sonnet-5"' "$out"
check "opus slug present" '"slug": "claude-opus-4-8"' "$out"
check "haiku slug present" '"slug": "claude-haiku-4-5"' "$out"

# --- every slug is a full model id, never a bare alias (see claude-review.sh's own findings) ---
check_absent "no bare 'sonnet' alias" '"slug": "sonnet"' "$out"
check_absent "no bare 'opus' alias" '"slug": "opus"' "$out"
check_absent "no bare 'haiku' alias" '"slug": "haiku"' "$out"

# --- output is valid JSON with the shared {models, recommended} contract ---
parse_rc="$(printf '%s' "$out" | sed 's/rc=0$//' | python3 -c '
import json
import sys

data = json.loads(sys.stdin.read())
assert isinstance(data, dict)
models = data["models"]
assert isinstance(models, list) and len(models) == 4
for m in models:
    assert isinstance(m["slug"], str) and m["slug"]
    assert isinstance(m["display_name"], str) and m["display_name"]
    assert isinstance(m["description"], str) and m["description"]
assert data["recommended"] in [m["slug"] for m in models]
print(0)
' 2>&1)"
check "output is valid JSON matching the {models, recommended} contract" "0" "$parse_rc"

# --- deterministic across repeated invocations (no discovery flakiness -- it is static) ---
out2="$(PATH="$NOBIN" bash "$SCRIPT" 2>&1; echo "rc=$?")"
check_rc "repeated invocation: same exit code" 0 "${out2##*rc=}"
if [[ "$out" == "$out2" ]]; then rep_rc=0; else rep_rc=1; fi
check_rc "repeated invocation: identical output" 0 "$rep_rc"
