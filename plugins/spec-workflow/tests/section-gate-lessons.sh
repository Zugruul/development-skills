#!/usr/bin/env bash
# section-gate-lessons.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file. This file assumes
# those are already in scope.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== gate.sh sequencing: lessons append happens before the pass marker is cleared =="
# SPEC §8.1 requires capture-before-clear (a process killed between the two
# steps must still leave the failure signal persisted). There is no reliable
# way to observe true runtime interleaving in a best-effort bash script
# without instrumenting a mid-execution kill, so this is a static order
# check on the red-gate branch's source: the record_lesson call must appear
# before the marker's rm -f.
gate_else_branch="$(awk '/^else$/{flag=1} flag; /^fi$/{if(flag) exit}' "$PLUGIN/scripts/gate.sh")"
# shellcheck disable=SC2016  # single quotes are intentional: literal grep patterns, not shell expansion
lesson_line="$(grep -n 'record_lesson "\$rc"' <<<"$gate_else_branch" | head -1 | cut -d: -f1)"
# shellcheck disable=SC2016  # single quotes are intentional: literal grep patterns, not shell expansion
marker_line="$(grep -n 'rm -f "\$MARKER"' <<<"$gate_else_branch" | head -1 | cut -d: -f1)"
if [[ -n "$lesson_line" && -n "$marker_line" && "$lesson_line" -lt "$marker_line" ]]; then
    echo "ok   gate.sh: lessons append precedes marker removal in the red-gate branch"
else
    echo "FAIL gate.sh: lessons append must precede marker removal (lesson_line=$lesson_line marker_line=$marker_line)"
    fails=$((fails + 1))
fi

echo "== gate enforcement (SW-020: lessons feed captures red-gate tail) =="
T3L="$(mktemp -d)"; mkdir -p "$T3L/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T3L/.claude/project.json"
( cd "$T3L" && git init -q . && git add .claude/project.json && git commit -q -m init )
out="$(cd "$T3L" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "lessons: green gate pass recorded" "GATE PASS recorded" "$out"
if [[ ! -f "$T3L/.claude/lessons.jsonl" ]]; then
    echo "ok   lessons: green gate appends nothing (no feed file created)"
else
    echo "FAIL lessons: green gate should not create/append to the lessons feed"
    fails=$((fails + 1))
fi
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="echo line-one; echo line-two; false"; json.dump(c,open(sys.argv[1],"w"))' \
    "$T3L/.claude/project.json"
out="$(cd "$T3L" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "lessons: red gate still reports GATE RED" "GATE RED" "$out"
if [[ ! -f "$T3L/.claude/gate-pass" ]]; then echo "ok   lessons: pass file removed on red"; else echo "FAIL lessons: pass file should be removed"; fails=$((fails+1)); fi
lessons_line="$(tail -n1 "$T3L/.claude/lessons.jsonl" 2>/dev/null)"
check "lessons: record has ts key" '"ts"' "$lessons_line"
check "lessons: record has exit key with nonzero value" '"exit": 1' "$lessons_line"
check "lessons: tail includes failing command's output" 'line-two' "$lessons_line"
if python3 -c 'import json,sys; json.loads(sys.argv[1])' "$lessons_line" >/dev/null 2>&1; then
    echo "ok   lessons: record is valid JSON"
else
    echo "FAIL lessons: record is not valid JSON: $lessons_line"
    fails=$((fails + 1))
fi
n_before="$(wc -l < "$T3L/.claude/lessons.jsonl" | tr -d ' ')"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[1],"w"))' \
    "$T3L/.claude/project.json"
out="$(cd "$T3L" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "lessons: subsequent green gate pass recorded" "GATE PASS recorded" "$out"
n_after="$(wc -l < "$T3L/.claude/lessons.jsonl" | tr -d ' ')"
if [[ "$n_before" == "$n_after" ]]; then
    echo "ok   lessons: a later green gate does not append to the feed"
else
    echo "FAIL lessons: green gate appended to the feed (before=$n_before after=$n_after)"
    fails=$((fails + 1))
fi
rm -rf "$T3L"

echo "== gate enforcement (lessons.jsonl excluded from fingerprint) =="
T3P="$(mktemp -d)"; mkdir -p "$T3P/.claude"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c["commands"]["gate"]="true"; json.dump(c,open(sys.argv[2],"w"))' \
    "$FIX/valid.project.json" "$T3P/.claude/project.json"
( cd "$T3P" && git init -q . && git add .claude/project.json && git commit -q -m init )
before="$(cd "$T3P" && bash "$PLUGIN/scripts/tree-state.sh")"
echo '{"ts":"2026-01-01T00:00:00Z","exit":1,"tail":"boom"}' > "$T3P/.claude/lessons.jsonl"
after="$(cd "$T3P" && bash "$PLUGIN/scripts/tree-state.sh")"
if [[ "$before" == "$after" ]]; then
    echo "ok   lessons: fingerprint unaffected by .claude/lessons.jsonl appearing"
else
    echo "FAIL lessons: fingerprint changed when .claude/lessons.jsonl appeared -- before=$before after=$after"
    fails=$((fails + 1))
fi
out="$(cd "$T3P" && bash "$PLUGIN/scripts/gate.sh" 2>&1)"
check "lessons-fingerprint: gate pass recorded despite pre-existing lessons feed" "GATE PASS recorded" "$out"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$T3P" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "lessons-fingerprint: move allowed with a pre-existing, untouched lessons feed" "rc=0" "$out"
rm -rf "$T3P"

echo "== setup-project: .gitignore covers the lessons feed =="
check "setup-project SKILL.md gitignores .claude/lessons.jsonl" '.claude/lessons.jsonl' "$(cat "$PLUGIN/skills/setup-project/SKILL.md")"
check "repo .gitignore covers .claude/lessons.jsonl" '.claude/lessons.jsonl' "$(cat "$(dirname "$(dirname "$PLUGIN")")/.gitignore")"

