#!/usr/bin/env bash
# section-two-pass-review-preflight.sh -- sourced by run-tests.sh; do not run
# standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
#
# #236 (CDX-031 gap #4): two-pass-review-preflight.sh checks that BOTH
# documented review passes (spec-compliance, code-quality) are recorded in
# telemetry for a task before it may move to "QA". KNOWN LIMITATION (see the
# script's own header comment and docs/design/cdx-E3.md's "Follow-up:
# #236"): this verifies RECORDS exist, not that they came from genuinely
# independent review sessions.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== two-pass review preflight (#236, CDX-031 gap #4: independent two-pass review) =="

TPS="$PLUGIN/scripts/two-pass-review-preflight.sh"

# _tp_rec <dir> <json> -- appends a raw telemetry line directly (bypassing
# telemetry.py's CLI) so fixtures can build records with an arbitrary `pass`
# value cheaply.
_tp_rec() {
    local dir="$1" json="$2"
    mkdir -p "$dir/.claude"
    printf '%s\n' "$json" >> "$dir/.claude/telemetry.jsonl"
}

# --- (a) both passes recorded for the task -> PASS.
T6A="$(mktemp -d)"
_tp_rec "$T6A" '{"kind":"review-round","task":"236","round":1,"verdict":"approved","pass":"spec-compliance","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6A" '{"kind":"review-round","task":"236","round":2,"verdict":"approved","pass":"code-quality","ts":"2026-01-01T01:00:00Z"}'
out="$(bash "$TPS" --root "$T6A" --task 236 2>&1)"; rc=$?
check_rc "two-pass: (a) both passes recorded -- exit 0" 0 "$rc"
check "two-pass: (a) both passes recorded -- silent stdout on pass" "" "$out"
rm -rf "$T6A"

# --- (b) only spec-compliance recorded -> FAIL, names code-quality missing.
T6B="$(mktemp -d)"
_tp_rec "$T6B" '{"kind":"review-round","task":"236","round":1,"verdict":"approved","pass":"spec-compliance","ts":"2026-01-01T00:00:00Z"}'
out="$(bash "$TPS" --root "$T6B" --task 236 2>&1)"; rc=$?
check_rc "two-pass: (b) only spec-compliance -- exit 2" 2 "$rc"
check "two-pass: (b) message is actionable (BLOCKED)" "BLOCKED" "$out"
check "two-pass: (b) message names code-quality as missing" "code-quality" "$out"
rm -rf "$T6B"

# --- (c) only code-quality recorded -> FAIL, names spec-compliance missing.
T6C="$(mktemp -d)"
_tp_rec "$T6C" '{"kind":"review-round","task":"236","round":1,"verdict":"approved","pass":"code-quality","ts":"2026-01-01T00:00:00Z"}'
out="$(bash "$TPS" --root "$T6C" --task 236 2>&1)"; rc=$?
check_rc "two-pass: (c) only code-quality -- exit 2" 2 "$rc"
check "two-pass: (c) message is actionable (BLOCKED)" "BLOCKED" "$out"
check "two-pass: (c) message names spec-compliance as missing" "spec-compliance" "$out"
rm -rf "$T6C"

# --- (d) neither recorded: missing telemetry.jsonl entirely -> FAIL, both
# named missing, no crash.
T6D="$(mktemp -d)"
mkdir -p "$T6D/.claude"
out="$(bash "$TPS" --root "$T6D" --task 236 2>&1)"; rc=$?
check_rc "two-pass: (d1) missing telemetry file -- exit 2" 2 "$rc"
check "two-pass: (d1) missing telemetry file -- names spec-compliance" "spec-compliance" "$out"
check "two-pass: (d1) missing telemetry file -- names code-quality" "code-quality" "$out"
rm -rf "$T6D"

# --- (d2) records exist, but only for a DIFFERENT task -> FAIL, both missing
# for the task actually being checked.
T6D2="$(mktemp -d)"
_tp_rec "$T6D2" '{"kind":"review-round","task":"999","round":1,"verdict":"approved","pass":"spec-compliance","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6D2" '{"kind":"review-round","task":"999","round":2,"verdict":"approved","pass":"code-quality","ts":"2026-01-01T01:00:00Z"}'
out="$(bash "$TPS" --root "$T6D2" --task 236 2>&1)"; rc=$?
check_rc "two-pass: (d2) records exist only for a different task -- exit 2" 2 "$rc"
check "two-pass: (d2) names spec-compliance" "spec-compliance" "$out"
check "two-pass: (d2) names code-quality" "code-quality" "$out"
rm -rf "$T6D2"

# --- (e) merge-dialogue review-round records (no `pass` field, e.g.
# auto-merge's round 1/2/3) present for the task do NOT satisfy either pass.
T6E="$(mktemp -d)"
_tp_rec "$T6E" '{"kind":"review-round","task":"236","round":1,"verdict":"approved","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6E" '{"kind":"review-round","task":"236","round":2,"verdict":"approved","ts":"2026-01-01T01:00:00Z"}'
_tp_rec "$T6E" '{"kind":"review-round","task":"236","round":3,"verdict":"approved","ts":"2026-01-01T02:00:00Z"}'
out="$(bash "$TPS" --root "$T6E" --task 236 2>&1)"; rc=$?
check_rc "two-pass: (e) no-pass merge-dialogue rounds do not satisfy either pass -- exit 2" 2 "$rc"
check "two-pass: (e) names spec-compliance" "spec-compliance" "$out"
check "two-pass: (e) names code-quality" "code-quality" "$out"
rm -rf "$T6E"

# --- (f) wiring: board-queue.sh's _do_move() calls two-pass-review-preflight.sh
# on the "qa" transition -- NOT on "in review". Fake `gh` as in
# section-gate-preflight.sh / section-red-first-preflight.sh.
_tp_gh_fixture() {
    local dir="$1" marker="$2"
    mkdir -p "$dir"
    cat >"$dir/gh" <<FAKE
#!/usr/bin/env bash
set -uo pipefail
case "\$1 \$2" in
    "project item-list") echo '{"items":[{"id":"ITEM_236","content":{"number":236}}]}' ;;
    "project item-edit") touch "$marker" 2>/dev/null; echo "edited" ;;
    *) echo "fake gh: unexpected: \$*" >&2; exit 1 ;;
esac
FAKE
    chmod +x "$dir/gh"
}

T6F="$(mktemp -d)"; mkdir -p "$T6F/.claude"
cp "$FIX/valid.project.yaml" "$T6F/.claude/project.yaml"
T6FGH="$(mktemp -d)"
MARKER_F="$T6FGH/mutated"
_tp_gh_fixture "$T6FGH" "$MARKER_F"
out="$(cd "$T6F" && PATH="$T6FGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 236 "QA" 2>&1)"; rc=$?
check "two-pass wiring: (f) move to QA blocked with no review-round telemetry" "BLOCKED" "$out"
if [[ "$rc" -ne 0 ]]; then
    echo "ok   two-pass wiring: (f) blocked move -- nonzero exit"
else
    echo "FAIL two-pass wiring: (f) blocked move -- nonzero exit (got rc=$rc)"
    fails=$((fails+1))
fi
if [[ -f "$MARKER_F" ]]; then
    echo "FAIL two-pass wiring: (f) blocked move must not reach gh project item-edit"
    fails=$((fails+1))
else
    echo "ok   two-pass wiring: (f) blocked move never reached gh project item-edit"
fi
rm -rf "$T6F" "$T6FGH"

# --- (g) wiring: both passes recorded -> move to QA succeeds, reaching gh.
T6G="$(mktemp -d)"; mkdir -p "$T6G/.claude"
cp "$FIX/valid.project.yaml" "$T6G/.claude/project.yaml"
_tp_rec "$T6G" '{"kind":"review-round","task":"236","round":1,"verdict":"approved","pass":"spec-compliance","ts":"2026-01-01T00:00:00Z"}'
_tp_rec "$T6G" '{"kind":"review-round","task":"236","round":2,"verdict":"approved","pass":"code-quality","ts":"2026-01-01T01:00:00Z"}'
T6GGH="$(mktemp -d)"
MARKER_G="$T6GGH/mutated"
_tp_gh_fixture "$T6GGH" "$MARKER_G"
out="$(cd "$T6G" && PATH="$T6GGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 236 "QA" 2>&1)"; rc=$?
check "two-pass wiring: (g) move to QA succeeds with both passes recorded" "moved #236 -> QA" "$out"
check_rc "two-pass wiring: (g) move to QA exit 0" 0 "$rc"
if [[ -f "$MARKER_G" ]]; then
    echo "ok   two-pass wiring: (g) allowed move reached gh project item-edit"
else
    echo "FAIL two-pass wiring: (g) allowed move should have reached gh project item-edit"
    fails=$((fails+1))
fi
rm -rf "$T6G" "$T6GGH"

# --- (h) regression: moving to a status OTHER than "QA" is completely
# unaffected by missing two-pass telemetry (e.g. "In review" itself, which
# has its own independent gate-preflight/red-first-preflight checks and no
# review-round telemetry at all here).
T6H="$(mktemp -d)"
( cd "$T6H" && git init -q -b main . && git commit -q --allow-empty -m init )
mkdir -p "$T6H/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T6H/.claude/project.json"
( cd "$T6H" && git add -A && git commit -q -m "fixture config" && git checkout -q -b feature )
mkdir -p "$T6H/tests" "$T6H/src"
echo t > "$T6H/tests/foo.sh"
( cd "$T6H" && git add tests/foo.sh && git commit -q -m "test(236): red" )
echo i > "$T6H/src/foo.sh"
( cd "$T6H" && git add src/foo.sh && git commit -q -m "feat(236): green" )
out="$(cd "$T6H" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "two-pass regression: (h) gate pass recorded on fixture" "GATE PASS recorded" "$out"
T6HGH="$(mktemp -d)"
MARKER_H="$T6HGH/mutated"
cat >"$T6HGH/gh" <<FAKE
#!/usr/bin/env bash
set -uo pipefail
case "\$1 \$2" in
    "project item-list") echo '{"items":[{"id":"ITEM_236","content":{"number":236}}]}' ;;
    "project item-edit") touch "$MARKER_H" 2>/dev/null; echo "edited" ;;
    *) echo "fake gh: unexpected: \$*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$T6HGH/gh"
out="$(cd "$T6H" && PATH="$T6HGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 236 "In review" 2>&1)"; rc=$?
check "two-pass regression: (h) move to 'In review' unaffected by missing two-pass telemetry" "moved #236 -> In review" "$out"
check_rc "two-pass regression: (h) move to 'In review' exit 0" 0 "$rc"
rm -rf "$T6H" "$T6HGH"

# --- (i) regression: moving to Backlog/Ready/Deployed is also unaffected.
T6I="$(mktemp -d)"; mkdir -p "$T6I/.claude"
cp "$FIX/valid.project.yaml" "$T6I/.claude/project.yaml"
T6IGH="$(mktemp -d)"
MARKER_I="$T6IGH/mutated"
_tp_gh_fixture "$T6IGH" "$MARKER_I"
for st in Backlog Ready Deployed; do
    out="$(cd "$T6I" && PATH="$T6IGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 236 "$st" 2>&1)"; rc=$?
    check "two-pass regression: (i) move to '$st' unaffected" "moved #236 -> $st" "$out"
    check_rc "two-pass regression: (i) move to '$st' exit 0" 0 "$rc"
done
rm -rf "$T6I" "$T6IGH"
