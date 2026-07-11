#!/usr/bin/env bash
# section-gate-fingerprint.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== gate enforcement (untracked-file content in fingerprint, SW-010) =="
T3U="$(mktemp -d)"
( cd "$T3U" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$T3U/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T3U/.claude/project.json"
echo '*.local' > "$T3U/.gitignore"
out="$(cd "$T3U" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "untracked: gate pass recorded" "GATE PASS recorded" "$out"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3U" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "untracked: move allowed right after pass" "rc=0" "$out"
echo new > "$T3U/untracked.txt"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3U" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "untracked: new untracked file blocks move" "tree changed since the last recorded gate pass" "$out"
out="$(cd "$T3U" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "untracked: gate re-recorded after add" "GATE PASS recorded" "$out"
echo modified >> "$T3U/untracked.txt"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3U" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "untracked: modifying an untracked file blocks move" "tree changed since the last recorded gate pass" "$out"
out="$(cd "$T3U" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "untracked: gate re-recorded after modify" "GATE PASS recorded" "$out"
rm -f "$T3U/untracked.txt"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3U" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "untracked: deleting an untracked file blocks move" "tree changed since the last recorded gate pass" "$out"
out="$(cd "$T3U" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "untracked: gate re-recorded after delete" "GATE PASS recorded" "$out"
echo ignored > "$T3U/churn.local"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3U" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "untracked: ignored-file churn does not invalidate pass" "rc=0" "$out"
echo changed >> "$T3U/churn.local"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3U" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "untracked: ignored-file modification does not invalidate pass" "rc=0" "$out"
rm -f "$T3U/churn.local"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3U" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "untracked: ignored-file deletion does not invalidate pass" "rc=0" "$out"
rm -rf "$T3U"

echo "== gate enforcement (gate-pass marker excluded even when .claude/ has a TRACKED file, SW-010 follow-up) =="
T3M="$(mktemp -d)"
mkdir -p "$T3M/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T3M/.claude/project.json"
( cd "$T3M" && git init -q . && git add .claude/project.json && git commit -q -m init )
# No .gitignore entry for .claude/gate-pass, and .claude/ has a tracked file so
# it can't collapse to a single "?? .claude/" porcelain line — this is the
# shape that exposes gate-pass to `git status --porcelain` once it exists.
# Compare tree-state.sh's raw output directly (not through gate.sh's record
# step): gate.sh's `>"$MARKER"` redirection happens to pre-create gate-pass
# before tree-state.sh runs, which accidentally masks the porcelain leak in
# that one call path — this direct comparison is the real, unmasked check.
before="$(cd "$T3M" && bash "$PLUGIN/scripts/tree-state.sh")"
: > "$T3M/.claude/gate-pass"
after="$(cd "$T3M" && bash "$PLUGIN/scripts/tree-state.sh")"
if [[ "$before" == "$after" ]]; then
    echo "ok   marker: fingerprint unaffected by .claude/gate-pass appearing in a tracked .claude/ dir"
else
    echo "FAIL marker: fingerprint changed when .claude/gate-pass appeared — before=$before after=$after"
    fails=$((fails + 1))
fi
rm -f "$T3M/.claude/gate-pass"
out="$(cd "$T3M" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "marker: gate pass recorded" "GATE PASS recorded" "$out"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3M" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "marker: move allowed immediately after pass despite tracked .claude dir" "rc=0" "$out"
rm -rf "$T3M"

echo "== gate enforcement (telemetry.jsonl excluded from fingerprint, SW-023 follow-up) =="
T3N="$(mktemp -d)"; mkdir -p "$T3N/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T3N/.claude/project.json"
( cd "$T3N" && git init -q . && git add .claude/project.json && git commit -q -m init )
before="$(cd "$T3N" && bash "$PLUGIN/scripts/tree-state.sh")"
echo '{"kind":"gate","task":"x","ok":true,"ts":"2026-01-01T00:00:00Z"}' > "$T3N/.claude/telemetry.jsonl"
after="$(cd "$T3N" && bash "$PLUGIN/scripts/tree-state.sh")"
if [[ "$before" == "$after" ]]; then
    echo "ok   telemetry: fingerprint unaffected by .claude/telemetry.jsonl appearing"
else
    echo "FAIL telemetry: fingerprint changed when .claude/telemetry.jsonl appeared -- before=$before after=$after"
    fails=$((fails + 1))
fi
rm -f "$T3N/.claude/telemetry.jsonl"

# Full integration: gate green, then a routine board.sh move (any task, any
# status) appends a transition event to the SAME telemetry.jsonl the pass was
# recorded against; the guard re-check for a DIFFERENT move must still see a
# VALID, current pass. Also a concurrency-safety property: one lane's routine
# move must not invalidate another lane's recorded pass (telemetry.jsonl is
# shared across the whole repo).
out="$(cd "$T3N" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "telemetry: gate pass recorded" "GATE PASS recorded" "$out"
T3NGH="$(mktemp -d)"
cat >"$T3NGH/gh" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
case "$1 $2" in
    "project item-list") echo '{"items":[{"id":"ITEM_7","content":{"number":7}}]}' ;;
    "project item-edit") echo "edited" ;;
    *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$T3NGH/gh"
out="$(cd "$T3N" && PATH="$T3NGH:$PATH" bash "$PLUGIN/scripts/board.sh" move 7 Backlog 2>&1)"
check "telemetry: routine move succeeded" "moved #7 -> Backlog" "$out"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3N" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "telemetry: a routine move must not invalidate a still-current gate pass" "rc=0" "$out"
rm -rf "$T3N" "$T3NGH"

