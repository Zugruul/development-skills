#!/usr/bin/env bash
# section-brain-outcome.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== brain outcome (GL-001/SPEC-GRAPHIFY §7: recall-outcome data layer) =="

BO_SCRIPTS="$PLUGIN/scripts"
BO="$(mktemp -d)"
mkdir -p "$BO/.claude"
cat >"$BO/.claude/project.yaml" <<'YAML'
schemaVersion: 2
project:
    name: acme/widgets
    mainBranch: main
YAML
bo_brain() { python3 "$BO_SCRIPTS/brain.py" "$BO" "$@"; }
BO_OUT="$BO/.claude/identities/dev/brain/outcomes.jsonl"

printf 'Some lesson body.\n' | bo_brain mint dev good-note --tags x --paths "x/**" --source "PR#1" >/dev/null

# ------------------------------------------------------------------- happy path
bo_brain outcome dev good-note useful >/dev/null
check "happy path: outcomes.jsonl created" "1" "$(wc -l <"$BO_OUT" | tr -d ' ')"
line1="$(sed -n '1p' "$BO_OUT")"
py_check() {
    python3 -c '
import json, sys
o = json.loads(sys.argv[1])
for k in ("schemaVersion", "ts", "slug", "outcome", "task", "note"):
    assert k in o, k
print("OK")
' "$1"
}
check "happy path: line is schema-valid JSON with all keys" "OK" "$(py_check "$line1")"
check "happy path: schemaVersion is 1" '"schemaVersion": 1' "$line1"
check "happy path: slug recorded" '"slug": "good-note"' "$line1"
check "happy path: outcome recorded" '"outcome": "useful"' "$line1"
check "happy path: task defaults to null" '"task": null' "$line1"
check "happy path: note defaults to null" '"note": null' "$line1"

# second call appends a second line
bo_brain outcome dev good-note dead_end >/dev/null
check "second call: two lines total" "2" "$(wc -l <"$BO_OUT" | tr -d ' ')"
line2="$(sed -n '2p' "$BO_OUT")"
check "second call: second line records dead_end" '"outcome": "dead_end"' "$line2"

# ------------------------------------------------------------- corrected + note
bo_brain outcome dev good-note corrected --note "the path glob was wrong" >/dev/null
check "corrected with note: three lines total" "3" "$(wc -l <"$BO_OUT" | tr -d ' ')"
line3="$(sed -n '3p' "$BO_OUT")"
check "corrected with note: note text recorded" '"note": "the path glob was wrong"' "$line3"

# corrected WITHOUT --note: non-zero exit, usage text, file unchanged
before="$(wc -l <"$BO_OUT" | tr -d ' ')"
err="$(bo_brain outcome dev good-note corrected 2>&1 >/dev/null)"; rc=$?
check_rc "corrected without --note: non-zero exit" 1 "$rc"
check "corrected without --note: usage/explanatory text" "--note" "$err"
after="$(wc -l <"$BO_OUT" | tr -d ' ')"
check "corrected without --note: file unchanged" "$before" "$after"

# ------------------------------------------------------------------ --task refs
bo_brain outcome dev good-note useful --task "#99" >/dev/null
line4="$(tail -n 1 "$BO_OUT")"
check "bare #99 stored fully qualified" '"task": "acme/widgets#99"' "$line4"

bo_brain outcome dev good-note useful --task "other/repo#7" >/dev/null
line5="$(tail -n 1 "$BO_OUT")"
check "already-qualified ref passes through unchanged" '"task": "other/repo#7"' "$line5"

# ------------------------------------------------------------- unknown role/slug
before="$(wc -l <"$BO_OUT" | tr -d ' ')"
err="$(bo_brain outcome nosuchrole good-note useful 2>&1 >/dev/null)"; rc=$?
check_rc "unknown role: non-zero exit" 1 "$rc"
check "unknown role: names the missing role" "nosuchrole" "$err"
after="$(wc -l <"$BO_OUT" | tr -d ' ')"
check "unknown role: nothing written to dev's file" "$before" "$after"

err="$(bo_brain outcome dev nosuchslug useful 2>&1 >/dev/null)"; rc=$?
check_rc "unknown slug: non-zero exit" 1 "$rc"
check "unknown slug: names the missing slug" "nosuchslug" "$err"
after2="$(wc -l <"$BO_OUT" | tr -d ' ')"
check "unknown slug: nothing written" "$before" "$after2"

# --------------------------------------------------------- absent file on reads
BO2="$(mktemp -d)"
mkdir -p "$BO2/.claude"
cp "$BO/.claude/project.yaml" "$BO2/.claude/project.yaml"
bo2_brain() { python3 "$BO_SCRIPTS/brain.py" "$BO2" "$@"; }
printf 'Another note.\n' | bo2_brain mint dev fresh-note --tags y --paths "y/**" --source "PR#2" >/dev/null
out="$(bo2_brain recall dev --paths "y/z.txt" --keywords "" 2>&1)"
check "absent outcomes.jsonl: recall still works" "fresh-note" "$out"
check_absent "absent outcomes.jsonl: no error surfaced" "Traceback" "$out"
rm -rf "$BO2"

# --------------------------------------------------------------- atomicity/concurrency
BO_N=20
for i in $(seq 1 "$BO_N"); do
    bo_brain outcome dev good-note useful --task "#$i" >/dev/null &
done
wait
out="$(python3 -c '
import json, sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().splitlines()
valid = 0
for ln in lines:
    o = json.loads(ln)   # raises on any torn/interleaved line
    assert set(o.keys()) == {"schemaVersion", "ts", "slug", "outcome", "task", "note"}
    valid += 1
print("VALID=%d" % valid)
' "$BO_OUT" 2>&1)"
check "concurrency: 20 parallel appends all valid JSON" "VALID=$((5 + BO_N))" "$out"

rm -rf "$BO"
