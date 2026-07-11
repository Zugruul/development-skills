#!/usr/bin/env bash
# section-gate-core.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== gate enforcement (gate.sh + guard-board-move hook) =="
T3="$(mktemp -d)"
( cd "$T3" && git init -q . && git commit -q --allow-empty -m init )
mkdir -p "$T3/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T3/.claude/project.json"
# hookjson/hookjsonpy are shared guard-hook stdin builders defined in _lib.sh
# (always sourced) so a single-section --section run still has them in scope.
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "move blocked without pass" "BLOCKED: no recorded gate pass" "$out"
check "block exit code 2" "rc=2" "$out"
out="$(hookjson 'bash board.sh comment 7 \"please move to in review\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "comment mentioning review status is allowed, no substring FP" "rc=0" "$out"
out="$(hookjson 'bash board.sh move 7 Backlog && gh issue comment 3 --body \"Please consider In review after QA\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "move to Backlog allowed despite embedded In review text (live incident)" "rc=0" "$out"
out="$(hookjson 'cd /tmp && bash /some/path/board.sh move 7 \"In review\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "compound command still parsed and blocked without pass" "rc=2" "$out"
out="$(hookjson 'echo \"moving to In review\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "non board.sh command mentioning status unaffected" "rc=0" "$out"
out="$(hookjson 'bash board.sh move 7 \"In review' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "unparseable board.sh move command fails closed" "BLOCKED: could not safely parse" "$out"
check "unparseable fail-closed exit code 2" "rc=2" "$out"
BASHC_MOVE='bash -c "board.sh move 9 '\''In review'\''"'
out="$(hookjsonpy "$BASHC_MOVE" | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "bash -c wrapped move to review blocked without pass" "rc=2" "$out"
SHC_MOVE='sh -c "board.sh move 9 '\''In review'\''"'
out="$(hookjsonpy "$SHC_MOVE" | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "sh -c wrapped move to review blocked without pass" "rc=2" "$out"
NESTED_BASHC='bash -c '\''bash -c "board.sh move 9 \"In review\""'\'''
out="$(hookjsonpy "$NESTED_BASHC" | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "nested bash -c move to review blocked without pass" "rc=2" "$out"
BASHC_COMMENT='bash -c '\''board.sh comment 9 "please move to In review"'\'''
out="$(hookjsonpy "$BASHC_COMMENT" | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "bash -c wrapped comment mentioning review status allowed, no FP" "rc=0" "$out"
out="$(cd "$T3" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "gate pass recorded" "GATE PASS recorded" "$out"
check "gate telemetry: ok:true event recorded" '"kind": "gate"' "$(cat "$T3/.claude/telemetry.jsonl" 2>/dev/null)"
check "gate telemetry: ok:true value" '"ok": true' "$(cat "$T3/.claude/telemetry.jsonl" 2>/dev/null)"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "move allowed with fresh pass" "rc=0" "$out"
out="$(hookjsonpy "$BASHC_MOVE" | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "bash -c wrapped move allowed with fresh pass" "rc=0" "$out"
echo dirty > "$T3/file.txt" && (cd "$T3" && git add file.txt)
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "stale pass re-blocked after edit" "tree changed since the last recorded gate pass" "$out"
out="$(hookjson 'bash board.sh move 7 QA' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "non-review moves unaffected" "rc=0" "$out"
out="$(hookjson 'ls -la' | (cd "$T3" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "unrelated commands unaffected" "rc=0" "$out"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="false"; json.dump(c,open(sys.argv[1],"w"))' "$T3/.claude/project.json"
out="$( (cd "$T3" && bash "$PLUGIN/scripts/gate.sh") 2>&1; echo "rc=$?")"
check "red gate clears pass" "GATE RED" "$out"
check "gate telemetry: ok:false event recorded on red" '"ok": false' "$(cat "$T3/.claude/telemetry.jsonl" 2>/dev/null)"
if [[ ! -f "$T3/.claude/gate-pass" ]]; then echo "ok   pass file removed on red"; else echo "FAIL pass file should be removed"; fails=$((fails+1)); fi
rm -rf "$T3"

