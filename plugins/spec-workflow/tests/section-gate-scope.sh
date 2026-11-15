#!/usr/bin/env bash
# section-gate-scope.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail, has sourced _lib.sh
# (check/check_rc/check_absent) and set HERE/PLUGIN/FIX/fails/flaky before
# sourcing this file. This file assumes those are already in scope.
#
# Gate scope: gate.sh runs a FAST subset of the gate tied to the files a
# branch changed (methodology.gateScope: affected, the default) instead of
# the whole gate, when the repo declares commands.gateAffected. `full` (config,
# --full, or SPEC_GATE_SCOPE=full) keeps the old run-everything behaviour.
# run-tests.sh --changed maps GATE_CHANGED_FILES to the sections that cover
# them; --list prints the selection without running it.
#
# Recursion guard: like section-runner-filter.sh, this section spawns
# run-tests.sh; every spawn sets _GATE_SCOPE_META=1 and the child returns here.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
if [[ -n "${_GATE_SCOPE_META:-}" ]]; then
    return 0
fi
echo "== gate scope (affected subset vs full) =="
RT="$HERE/run-tests.sh"
GS_PFX="plugins/spec-workflow"

# --- run-tests.sh --list / --changed ---------------------------------------
gs_list() { # $1 = newline-separated changed files; prints the selected sections
    _GATE_SCOPE_META=1 _RUNNER_FILTER_META=1 GATE_CHANGED_FILES="$1" bash "$RT" --changed --list 2>/dev/null
}
GS_ALL="$(_GATE_SCOPE_META=1 _RUNNER_FILTER_META=1 bash "$RT" --list 2>/dev/null)"; rc=$?
check_rc "r1 --list exits 0" 0 "$rc"
check    "r1 --list prints registered sections" "section-gate-scope.sh" "$GS_ALL"
check_absent "r1 --list runs nothing" "== syntax ==" "$GS_ALL"
GS_ALL_N="$(printf '%s\n' "$GS_ALL" | grep -c '^section-')"

out="$(gs_list "$GS_PFX/scripts/red-first-preflight.sh")"
check        "r2 changed script selects its section" "section-red-first-preflight.sh" "$out"
check        "r2 changed script selects every section naming it" "section-preflight-worktree-base.sh" "$out"
check        "r2 always-run lint section included" "section-syntax.sh" "$out"
check_absent "r2 unrelated section skipped" "section-neural-view-lifecycle.sh" "$out"

out="$(gs_list "$GS_PFX/scripts/telemetry.py")"
check "r2b a changed module also selects sections driving its direct callers (board.sh)" "section-serial-delivery.sh" "$out"
check_rc "r2c caller expansion stops at one level (not the full suite)" 1 "$([[ "$(printf '%s\n' "$out" | grep -c '^section-')" -lt "$GS_ALL_N" ]] && echo 1 || echo 0)"

out="$(gs_list "$GS_PFX/tests/section-repo-root.sh")"
check "r3 changed section file selects itself" "section-repo-root.sh" "$out"

out="$(gs_list "$GS_PFX/tests/_lib.sh")"
check_rc "r4 runner infra change -> full suite" "$GS_ALL_N" "$(printf '%s\n' "$out" | grep -c '^section-')"
out="$(gs_list "$GS_PFX/tests/run-tests.sh")"
check_rc "r4b run-tests.sh change -> full suite" "$GS_ALL_N" "$(printf '%s\n' "$out" | grep -c '^section-')"

out="$(gs_list "$GS_PFX/scripts/zz-unreferenced-$$.py")"
check_rc "r5 plugin code no section names -> full suite (safe)" "$GS_ALL_N" "$(printf '%s\n' "$out" | grep -c '^section-')"

out="$(gs_list "docs/zz-notes-$$.md")"
check        "r6 unrelated doc -> always-run sections only" "section-syntax.sh" "$out"
check_absent "r6 unrelated doc skips the rest" "section-red-first-preflight.sh" "$out"
out="$(gs_list "$GS_PFX/skills/gate/references/zz-$$.md")"
check_absent "r7 unreferenced plugin markdown does not force the full suite" "section-red-first-preflight.sh" "$out"

out="$(gs_list "$GS_PFX/skills/setup-project/SKILL.md")"
check        "r8 SKILL.md matched by <skill>/SKILL.md" "section-gate-scope.sh" "$out"
check_absent "r8 a SKILL.md change does not select every SKILL.md test" "section-red-first-preflight.sh" "$out"

out="$(gs_list "")"; rc=$?
check_rc     "r9 empty change set exits 0" 0 "$rc"
check        "r9 empty change set still runs always-run sections" "section-syntax.sh" "$out"
check_absent "r9 empty change set skips the rest" "section-gate-core.sh" "$out"

out="$(_GATE_SCOPE_META=1 GATE_CHANGED_FILES="x" bash "$RT" --changed --section syntax --list 2>&1)"; rc=$?
check_rc "r10 --changed with --section is refused" 2 "$rc"

out="$(_GATE_SCOPE_META=1 _RUNNER_FILTER_META=1 GATE_CHANGED_FILES="$GS_PFX/scripts/gate.sh" bash "$RT" --changed --list 2>&1 >/dev/null)"
check "r11 --changed reports its selection size" "of $GS_ALL_N sections" "$out"

out="$(_GATE_SCOPE_META=1 _RUNNER_FILTER_META=1 GATE_CHANGED_FILES="docs/zz-$$.md" bash "$RT" --changed 2>&1)"; rc=$?
check_rc "r12 --changed actually runs the selection green" 0 "$rc"
check    "r12 --changed ran the always-run syntax section" "== syntax ==" "$out"

GS_LINK="$(mktemp -d)"
ln -s "$(cd "$PLUGIN/../.." && pwd -P)" "$GS_LINK/repo"
GS_LRT="$GS_LINK/repo/$GS_PFX/tests/run-tests.sh"
out="$(_GATE_SCOPE_META=1 _RUNNER_FILTER_META=1 GATE_CHANGED_FILES="$GS_PFX/tests/_lib.sh" bash "$GS_LRT" --changed --list 2>/dev/null)"
check_rc "r13 symlinked checkout: runner infra change still -> full suite" "$GS_ALL_N" "$(printf '%s\n' "$out" | grep -c '^section-')"
out="$(_GATE_SCOPE_META=1 _RUNNER_FILTER_META=1 GATE_CHANGED_FILES="$GS_PFX/scripts/zz-unreferenced-$$.py" bash "$GS_LRT" --changed --list 2>/dev/null)"
check_rc "r13b symlinked checkout: uncovered plugin file still -> full suite" "$GS_ALL_N" "$(printf '%s\n' "$out" | grep -c '^section-')"
rm -rf "$GS_LINK"

out="$(env -u GATE_CHANGED_FILES _GATE_SCOPE_META=1 _RUNNER_FILTER_META=1 bash "$RT" --changed --list 2>&1)"
check_rc "r14 --changed with GATE_CHANGED_FILES unset runs the full suite" "$GS_ALL_N" "$(printf '%s\n' "$out" | grep -c '^section-')"
check    "r14 ... and says why" "GATE_CHANGED_FILES is not set" "$out"

# --- gate.sh scope resolution ----------------------------------------------
GS="$(mktemp -d)"
git init -q --bare "$GS/origin.git"
git -C "$GS/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$GS/origin.git" "$GS/w" 2>/dev/null
git -C "$GS/w" symbolic-ref HEAD refs/heads/main
mkdir -p "$GS/w/.neural-network"
printf 'base\n' > "$GS/w/tracked.txt"
printf '.claude/\n' > "$GS/w/.gitignore"
gs_cfg() { # $1 = python snippet mutating c
    # shellcheck disable=SC2016 # $GATE_* expand inside the gate command, not here
    python3 -c 'import json,sys
c=json.load(open(sys.argv[1]))
c["project"]["mainBranch"]="main"
c["commands"]["gate"]="echo FULL-RAN"
c["commands"]["gateAffected"]="echo AFFECTED-RAN base=$GATE_BASE; echo \"CHANGED<<$GATE_CHANGED_FILES>>\""
exec(sys.argv[3])
json.dump(c,open(sys.argv[2],"w"))' "$FIX/valid.project.json" "$GS/w/.neural-network/project.json" "$1"
}
gs_cfg ''
( cd "$GS/w" && git add -A && git -c user.name=t -c user.email=t@t commit -qm base && git push -q origin main 2>/dev/null )
git -C "$GS/w" checkout -qb feat
printf 'a\n' > "$GS/w/committed.txt"
( cd "$GS/w" && git add committed.txt && git -c user.name=t -c user.email=t@t commit -qm feat )
printf 'mod\n' >> "$GS/w/tracked.txt"
printf 'u\n' > "$GS/w/untracked.txt"
# env -u: an exported SPEC_GATE_SCOPE / GATE_* in the caller must not leak in.
# Usage: gs_gate [VAR=value...] [gate.sh args...]
gs_gate() {
    local -a _envs=()
    while [[ $# -gt 0 && "$1" == *=* ]]; do _envs+=("$1"); shift; done
    (cd "$GS/w" && env -u SPEC_GATE_SCOPE -u GATE_CHANGED_FILES -u GATE_BASE ${_envs[@]+"${_envs[@]}"} bash "$PLUGIN/scripts/gate.sh" "$@" 2>&1)
}

out="$(gs_gate)"; rc=$?
check_rc     "g1 default scope gate exits 0" 0 "$rc"
check        "g1 default scope is affected" "gate scope: affected" "$out"
check        "g1 runs commands.gateAffected" "AFFECTED-RAN" "$out"
check_absent "g1 does not run the full gate" "FULL-RAN" "$out"
check        "g1 committed branch change listed" "committed.txt" "$out"
check        "g1 uncommitted tracked change listed" "tracked.txt" "$out"
check        "g1 untracked file listed" "untracked.txt" "$out"
check_absent "g1 gitignored local state not listed" ".claude/" "$(printf '%s\n' "$out" | sed -n '/CHANGED<</,/>>/p')"
check        "g1 GATE_BASE exported" "base=$(git -C "$GS/w" merge-base HEAD origin/main)" "$out"
check        "g1 pass recorded under affected scope" "GATE PASS recorded" "$out"
check        "g1 telemetry records scope" '"scope": "affected"' "$(cat "$GS/w/.claude/telemetry.jsonl" 2>/dev/null)"
out="$(hookjson 'bash board.sh move 7 \"In review\"' | (cd "$GS/w" && bash "$PLUGIN/scripts/guard-board-move.sh" 2>&1); echo "rc=$?")"
check "g1 an affected-scope pass unlocks In review" "rc=0" "$out"

out="$(gs_gate --full)"
check        "g2 --full runs the full gate" "FULL-RAN" "$out"
check_absent "g2 --full skips gateAffected" "AFFECTED-RAN" "$out"
check        "g2 --full announces full scope" "gate scope: full" "$out"

out="$(gs_gate SPEC_GATE_SCOPE=full)"
check "g3 SPEC_GATE_SCOPE=full runs the full gate" "FULL-RAN" "$out"

gs_cfg 'c.setdefault("methodology",{})["gateScope"]="full"'
out="$(gs_gate)"
check        "g4 methodology.gateScope=full runs the full gate" "FULL-RAN" "$out"
check_absent "g4 gateScope=full skips gateAffected" "AFFECTED-RAN" "$out"
out="$(gs_gate --affected)"
check "g4b --affected overrides config full" "AFFECTED-RAN" "$out"

gs_cfg 'c.setdefault("methodology",{})["gateScope"]="sometimes"'
out="$(gs_gate)"; rc=$?
check_rc "g5 invalid gateScope refused" 2 "$rc"
check    "g5 invalid gateScope names the valid values" "affected|full" "$out"

gs_cfg 'del c["commands"]["gateAffected"]'
out="$(gs_gate)"; rc=$?
check_rc "g6 no gateAffected still gates" 0 "$rc"
check    "g6 no gateAffected falls back to the full gate" "FULL-RAN" "$out"
check    "g6 fallback is explained" "no commands.gateAffected" "$out"

gs_cfg 'c["project"]["mainBranch"]="nope"'
out="$(gs_gate)"
check "g7 unresolvable base falls back to the full gate" "FULL-RAN" "$out"
check "g7 fallback names the missing base" "could not resolve" "$out"

out="$(gs_gate --bogus)"; rc=$?
check_rc "g8 unknown gate.sh argument refused" 2 "$rc"

# g9: a multi-line commands.gate keeps its newlines (each line is a command)
gs_cfg 'c["commands"]["gate"]="echo LINE-ONE\necho LINE-TWO"; c.setdefault("methodology",{})["gateScope"]="full"'
out="$(gs_gate)"
check "g9 multi-line gate: first line runs" "LINE-ONE" "$out"
check "g9 multi-line gate: second line runs as its own command" $'\nLINE-TWO' "$out"
check_absent "g9 multi-line gate is not flattened into one command" "LINE-ONE echo" "$out"
gs_cfg 'c["commands"]["gateAffected"]="echo AFF-ONE\necho AFF-TWO"'
out="$(gs_gate)"
check "g9b multi-line gateAffected keeps its newlines" $'\nAFF-TWO' "$out"

# g10: a rename lists the OLD path too (sections naming it must still run)
gs_cfg ''
git -C "$GS/w" checkout -q -- tracked.txt 2>/dev/null; rm -f "$GS/w/untracked.txt"
( cd "$GS/w" && git mv committed.txt renamed.txt && git -c user.name=t -c user.email=t@t commit -qm mv )
out="$(gs_gate)"
check "g10 rename: new path listed" "renamed.txt" "$out"
check "g10 rename: old path listed" "committed.txt" "$out"

# g11: non-ASCII names arrive unquoted
printf 'x\n' > "$GS/w/café.txt"
out="$(gs_gate)"
check        "g11 non-ASCII path listed verbatim" "café.txt" "$out"
check_absent "g11 non-ASCII path not C-quoted" '"caf' "$out"
rm -rf "$GS"

# --- schema, template, docs -------------------------------------------------
out="$(python3 -c 'import json,sys
s=json.load(open(sys.argv[1]))["properties"]
m=s["methodology"]["properties"]["gateScope"]
print("enum", sorted(m["enum"]), "default", m["default"])
print("cmd", "gateAffected" in s["commands"]["properties"])' "$PLUGIN/schemas/project-config.schema.json" 2>&1)"
check "s1 schema: methodology.gateScope enum" "enum ['affected', 'full'] default affected" "$out"
check "s2 schema: commands.gateAffected declared" "cmd True" "$out"
check "s3 template writes gateScope" "gateScope: affected" "$(cat "$PLUGIN/templates/project.example.yaml")"
check "s4 template shows gateAffected commented out (no foreign placeholder runs)" "# gateAffected:" "$(cat "$PLUGIN/templates/project.example.yaml")"
check_absent "s4b template has no live gateAffected" $'\n    gateAffected:' "$(cat "$PLUGIN/templates/project.example.yaml")"
GSV="$(mktemp -d)"
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); c.setdefault("methodology",{})["gateScope"]="subset"; c["commands"]["gateAffected"]=["x"]; json.dump(c,open(sys.argv[2],"w"))' "$FIX/valid.project.json" "$GSV/project.json"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$GSV/project.json" 2>&1)"
check "v1 validate-config rejects an unknown gateScope" "methodology.gateScope" "$out"
check "v2 validate-config rejects a non-string gateAffected" "commands.gateAffected" "$out"
rm -rf "$GSV"
check_absent "m1 gate.sh refusal no longer claims every pass is full-suite" "must be a full-suite run" "$(cat "$PLUGIN/scripts/gate.sh")"
check "m2 merge freshness waits for CI or runs the full gate" "gate.sh --full" "$(cat "$PLUGIN/skills/build-next/references/auto-review.md")"
check "m3 merge dance re-gate names the full gate fallback" "gate.sh --full" "$(cat "$PLUGIN/skills/build-next/references/concurrency.md")"
check "m4 session banner shows the gate scope" "methodology.gateScope" "$(cat "$PLUGIN/scripts/session-start.sh")"
check "d1 setup-project asks for gate scope" 'header "Gate scope"' "$(cat "$PLUGIN/skills/setup-project/SKILL.md")"
check "d2 gate skill documents gateScope" "methodology.gateScope" "$(cat "$PLUGIN/skills/gate/SKILL.md")"
check "d3 README documents gateScope" "gateScope" "$(cat "$PLUGIN/README.md")"
