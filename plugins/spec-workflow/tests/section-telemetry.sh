#!/usr/bin/env bash
# section-telemetry.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== telemetry.py record (validation + append) =="
TT="$(mktemp -d)"; mkdir -p "$TT/.claude"
rec() { python3 "$PLUGIN/scripts/telemetry.py" "$TT" record "$1" 2>&1; }
check "record: unknown kind rejected" "INVALID" "$(rec '{"kind":"bogus","task":"1","ts":"2026-01-01T00:00:00Z"}')"
check "record: malformed json rejected" "INVALID" "$(rec 'not-json')"
check "record: missing ts rejected" "INVALID" "$(rec '{"kind":"gate","task":"1","ok":true}')"
check "record: transition ok" "OK: recorded transition" "$(rec '{"kind":"transition","task":"1","from":"","to":"In progress","ts":"2026-01-01T00:00:00Z"}')"
check "record: gate ok" "OK: recorded gate" "$(rec '{"kind":"gate","task":"1","ok":true,"ts":"2026-01-01T01:00:00Z"}')"
check "record: gate.ok must be boolean" "INVALID" "$(rec '{"kind":"gate","task":"1","ok":"yes","ts":"2026-01-01T01:00:00Z"}')"
check "record: review-round ok" "OK: recorded review-round" "$(rec '{"kind":"review-round","task":"1","round":1,"verdict":"approved","ts":"2026-01-01T02:00:00Z"}')"
check "record: review-round.round must be an int" "INVALID" "$(rec '{"kind":"review-round","task":"1","round":"one","verdict":"approved","ts":"2026-01-01T02:00:00Z"}')"
check "record: task-close ok" "OK: recorded task-close" "$(rec '{"kind":"task-close","task":"1","estimate":3,"ts":"2026-01-01T03:00:00Z"}')"
check "record: task-close.estimate must be a number" "INVALID" "$(rec '{"kind":"task-close","task":"1","estimate":"big","ts":"2026-01-01T03:00:00Z"}')"
n="$(wc -l < "$TT/.claude/telemetry.jsonl" | tr -d ' ')"
if [[ "$n" == "4" ]]; then echo "ok   record: 4 valid records appended, invalid ones did not land"
else echo "FAIL record: expected 4 lines in telemetry.jsonl, got $n"; fails=$((fails + 1)); fi
rm -rf "$TT"

echo "== telemetry.py metrics (missing / garbage log) =="
TE="$(mktemp -d)"; mkdir -p "$TE/.claude"
check "metrics: missing log" "no telemetry yet" "$(python3 "$PLUGIN/scripts/telemetry.py" "$TE" metrics)"
printf 'not json\n{"kind":"bogus","task":"1","ts":"x"}\n' > "$TE/.claude/telemetry.jsonl"
out="$(python3 "$PLUGIN/scripts/telemetry.py" "$TE" metrics 2>&1)"
check "metrics: garbage-only log reports no telemetry" "no telemetry yet" "$out"
check "metrics: garbage-only log reports skip count on stderr" "skipped 2 malformed line(s)" "$out"
rm -rf "$TE"

echo "== telemetry.py metrics (fixture log: cycle time, gate, rework, estimate) =="
TF="$(mktemp -d)"; mkdir -p "$TF/.claude"
cp "$FIX/telemetry.jsonl" "$TF/.claude/telemetry.jsonl"
out="$(python3 "$PLUGIN/scripts/telemetry.py" "$TF" metrics 2>&1)"
check "metrics: tasks/events/skipped summary" "tasks=3 events=15 skipped=2" "$out"
check "metrics: cycle time avg for In progress" "In progress  avg=6.0h  n=2" "$out"
check "metrics: cycle time avg for In review" "In review  avg=2.0h  n=2" "$out"
check "metrics: gate first-try rate" "gate first-try rate: 50.0% (1/2 tasks)" "$out"
check "metrics: rework rate" "rework rate: 50.0% (1/2 tasks with review rounds)" "$out"
check "metrics: estimate vs actual task 10" "task=10  estimate=3  actual=6.0h" "$out"
check "metrics: estimate vs actual task 11" "task=11  estimate=5  actual=10.0h" "$out"
rm -rf "$TF"

echo "== board.sh metrics (delegates to telemetry.py) =="
BMT="$(mktemp -d)"; mkdir -p "$BMT/.claude"
cp "$FIX/valid.project.yaml" "$BMT/.claude/project.yaml"
cp "$FIX/telemetry.jsonl" "$BMT/.claude/telemetry.jsonl"
out="$(cd "$BMT" && bash "$PLUGIN/scripts/board.sh" metrics 2>&1)"
check "board.sh metrics delegates to telemetry.py" "gate first-try rate: 50.0% (1/2 tasks)" "$out"
rm -rf "$BMT"

echo "== board.sh move telemetry (transition events; move never fails on telemetry write failure) =="
BM="$(mktemp -d)"; mkdir -p "$BM/.claude"
cp "$FIX/valid.project.yaml" "$BM/.claude/project.yaml"
BMGH="$(mktemp -d)"
cat >"$BMGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
    "project item-list") echo '{"items":[{"id":"ITEM_1","content":{"number":1}}]}' ;;
    "project item-edit") echo "edited" ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$BMGH/gh"

out="$(cd "$BM" && PATH="$BMGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 1 "In progress" 2>&1; echo "rc=$?")"
check "move telemetry: move still reports success" "moved #1 -> In progress" "$out"
check "move telemetry: exits 0" "rc=0" "$out"
check "move telemetry: transition event appended" '"kind": "transition"' "$(cat "$BM/.claude/telemetry.jsonl" 2>/dev/null)"
check "move telemetry: to field set" '"to": "In progress"' "$(cat "$BM/.claude/telemetry.jsonl" 2>/dev/null)"
check "move telemetry: task field set" '"task": "1"' "$(cat "$BM/.claude/telemetry.jsonl" 2>/dev/null)"

BM2="$(mktemp -d)"; mkdir -p "$BM2/.claude"
cp "$FIX/valid.project.yaml" "$BM2/.claude/project.yaml"
chmod 555 "$BM2/.claude"
out2="$(cd "$BM2" && PATH="$BMGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 1 "In progress" 2>&1; echo "rc=$?")"
chmod 755 "$BM2/.claude"
check "move telemetry: unwritable .claude does not fail the move" "moved #1 -> In progress" "$out2"
check "move telemetry: unwritable .claude -- still exits 0" "rc=0" "$out2"
rm -rf "$BM" "$BM2" "$BMGH"

