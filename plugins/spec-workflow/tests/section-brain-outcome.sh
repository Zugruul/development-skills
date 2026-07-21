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

echo "== brain outcome event emission (GL-002/SPEC-GRAPHIFY §7 R7.2: RecallOutcome -> brain-events.jsonl) =="

# oe_summary <feed> -- print RecallOutcome line count + field snapshot of the
# LAST such line, so tests can assert shape without hand-parsing JSON inline.
oe_summary() {
    python3 - "$1" <<'PY'
import json, os, sys
feed = sys.argv[1]
n = 0
last = None
lines = []
if os.path.exists(feed):
    for ln in open(feed, encoding="utf-8"):
        ln = ln.strip()
        if not ln:
            continue
        lines.append(ln)
        e = json.loads(ln)   # raises on any torn/malformed line
        if e.get("type") == "RecallOutcome":
            n += 1
            last = e
print("N=%d" % n)
print("TOTAL_LINES=%d" % len(lines))
if last is not None:
    for k in ("role", "slug", "outcome", "task"):
        print("%s=%s" % (k.upper(), last.get(k)))
    print("HAS_TS=%s" % ("ts" in last))
PY
}

# ------------------------------------------------------------- happy path: event shape
OE="$(mktemp -d)"
mkdir -p "$OE/.claude"
cat >"$OE/.claude/project.yaml" <<'YAML'
schemaVersion: 2
project:
    name: acme/widgets
    mainBranch: main
YAML
oe_brain() { python3 "$BO_SCRIPTS/brain.py" "$OE" "$@"; }
OE_FEED="$OE/.claude/brain-events.jsonl"
printf 'Some lesson body.\n' | oe_brain mint dev evt-note --tags x --paths "x/**" --source "PR#1" >/dev/null
: >"$OE_FEED"   # isolate from the NoteMinted/LinkFormed events minting just emitted

oe_brain outcome dev evt-note useful --task "#7" >/dev/null
out="$(oe_summary "$OE_FEED")"
check "happy path: exactly one RecallOutcome line"   "N=1"                    "$out"
check "happy path: role carried through"             "ROLE=dev"               "$out"
check "happy path: slug carried through"              "SLUG=evt-note"          "$out"
check "happy path: outcome carried through"           "OUTCOME=useful"         "$out"
check "happy path: task carried through (qualified)"  "TASK=acme/widgets#7"    "$out"
check "happy path: ts field present"                  "HAS_TS=True"            "$out"

# ------------------------------------------------ outcomes.jsonl still lands too
check "happy path: outcomes.jsonl still got its line" "1" "$(wc -l <"$OE/.claude/identities/dev/brain/outcomes.jsonl" | tr -d ' ')"

rm -rf "$OE"

# ---------------------------------------- pre-existing event lines parse unchanged
OE="$(mktemp -d)"
mkdir -p "$OE/.claude"
oe_brain() { python3 "$BO_SCRIPTS/brain.py" "$OE" "$@"; }
OE_FEED="$OE/.claude/brain-events.jsonl"
printf 'body\n' | oe_brain mint dev pre-note --tags x --paths "x/**" >/dev/null
preexisting_line='{"v":1,"ts":"2020-01-01T00:00:00Z","repo":"acme/widgets","role":"dev","type":"LinkPruned","key":"a->b","reason":"target missing"}'
printf '%s\n' "$preexisting_line" >>"$OE_FEED"
before_hash="$(shasum "$OE_FEED" | awk '{print $1}')"

oe_brain outcome dev pre-note useful >/dev/null
after_first_lines="$(sed '$d' "$OE_FEED")"
check "pre-existing lines: byte-unchanged after a new emission" "$before_hash" "$(printf '%s\n' "$after_first_lines" | shasum | awk '{print $1}')"
check "pre-existing lines: LinkPruned line still parses"        "OK" "$(python3 -c '
import json, sys
json.loads(sys.argv[1])
print("OK")
' "$preexisting_line")"
out="$(oe_summary "$OE_FEED")"
check "pre-existing lines: new RecallOutcome appended after"    "N=1" "$out"
# feed already carries the mint's own NoteMinted line + the seeded LinkPruned
# line before the outcome call adds its RecallOutcome -> three lines total.
check "pre-existing lines: total feed lines is three"           "TOTAL_LINES=3" "$out"

rm -rf "$OE"

# --------------------------------------------------- feed-write failure never load-bearing
OE="$(mktemp -d)"
mkdir -p "$OE/.claude"
oe_brain() { python3 "$BO_SCRIPTS/brain.py" "$OE" "$@"; }
printf 'body\n' | oe_brain mint dev fail-note --tags x --paths "x/**" >/dev/null
rm -f "$OE/.claude/brain-events.jsonl"      # mint's NoteMinted emit already created it as a file
mkdir -p "$OE/.claude/brain-events.jsonl"   # feed target is a directory -> append is doomed

out="$(oe_brain outcome dev fail-note useful 2>&1)"; rc=$?
check_rc "feed-write failure: outcome command still exits 0" 0 "$rc"
check "feed-write failure: outcome command still reports success" "recorded outcome: dev/fail-note useful" "$out"
check "feed-write failure: a warning is printed"              "warning"     "$out"
check_absent "feed-write failure: no traceback"                "Traceback"   "$out"
check "feed-write failure: outcomes.jsonl line still lands"    "1" "$(wc -l <"$OE/.claude/identities/dev/brain/outcomes.jsonl" | tr -d ' ')"

rm -rf "$OE"

# --------------------------------------------------------- missing .claude root: skip cleanly
OE="$(mktemp -d)"                      # root has NO .claude at all
OE_IDENT="$(mktemp -d)/identities"     # identities dir lives entirely outside root/.claude
mkdir -p "$OE_IDENT/dev/brain/notes"
printf 'standalone body\n' >"$OE_IDENT/dev/brain/notes/standalone.md"
oe_brain_nodir() { python3 "$BO_SCRIPTS/brain.py" "$OE" --dir "$OE_IDENT" "$@"; }

out="$(oe_brain_nodir outcome dev standalone useful 2>&1)"; rc=$?
check_rc "missing .claude root: outcome command still exits 0" 0 "$rc"
check "missing .claude root: outcomes.jsonl line still lands" "1" "$(wc -l <"$OE_IDENT/dev/brain/outcomes.jsonl" | tr -d ' ')"
check "missing .claude root: no .claude dir is created under root" "ABSENT" "$([ -d "$OE/.claude" ] && echo PRESENT || echo ABSENT)"

rm -rf "$OE" "$(dirname "$OE_IDENT")"
