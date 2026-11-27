#!/usr/bin/env bash
# Behavioral mutation-boundary admission tests; isolated fake GitHub state.
declare -F check >/dev/null 2>&1 || { echo "run via run-tests.sh" >&2; exit 2; }
echo "== host-neutral WIP admission (#240) =="
python3 "$HERE/test_wip_admission.py"
check_rc "WIP mutation admission contracts" 0 "$?"

echo "== over-WIP moves and separate limits (#560/#563) =="
python3 "$HERE/test_over_wip.py"
check_rc "over-WIP and separate WIP limits" 0 "$?"
WL="$(mktemp -d)"
sed '/^    maxInProgress: 1/a\
    wipLimits:\
      inProgress: 2\
      inReview: 3
' "$FIX/valid.project.yaml" > "$WL/good.project.yaml"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$WL/good.project.yaml")"
check "wipLimits valid config passes" "VALID: " "$out"
for bad in "inProgress: 0" "inProgress: two" "inReview: true" "bogus: 1"; do
    sed "/^    maxInProgress: 1/a\\
    wipLimits:\\
      $bad
" "$FIX/valid.project.yaml" > "$WL/bad.project.yaml"
    out="$(python3 "$PLUGIN/scripts/validate-config.py" "$WL/bad.project.yaml" || true)"
    check "wipLimits rejects '$bad'" "methodology.wipLimits" "$out"
done
mkdir -p "$WL/repo/.claude" "$WL/repo/.neural-network"; ( cd "$WL/repo" && git init -q . )
cp "$WL/good.project.yaml" "$WL/repo/.neural-network/project.yaml"
check "concurrency status shows both limits" "In progress 2, In review 3" "$(cd "$WL/repo" && bash "$PLUGIN/scripts/concurrency.sh" status)"
check "schema documents wipLimits" '"wipLimits"' "$(cat "$PLUGIN/schemas/project-config.schema.json")"
check "README documents wipLimits" "wipLimits" "$(cat "$PLUGIN/README.md")"
check "README documents --over-wip" "--over-wip" "$(cat "$PLUGIN/README.md")"
check "implement-task registration passes --over-wip" "--over-wip" "$(cat "$PLUGIN/skills/implement-task/SKILL.md")"
check "build-next registration passes --over-wip" "--over-wip" "$(cat "$PLUGIN/skills/build-next/SKILL.md")"
check "concurrency skill documents wipLimits" "wipLimits" "$(cat "$PLUGIN/skills/concurrency/SKILL.md")"
sed '/^    maxInProgress: 1/a\
    wipLimits: {}
' "$FIX/valid.project.yaml" > "$WL/empty.project.yaml"
out="$(python3 "$PLUGIN/scripts/validate-config.py" "$WL/empty.project.yaml" || true)"
check "empty wipLimits rejected" "methodology.wipLimits: must set inProgress and/or inReview" "$out"
check "schema requires a key in wipLimits" '"minProperties": 1' "$(cat "$PLUGIN/schemas/project-config.schema.json")"
sed '/^    maxInProgress: 1/a\
    wipLimits:\
      inProgress: 2
' "$FIX/valid.project.yaml" > "$WL/only-progress.project.yaml"
cp "$WL/only-progress.project.yaml" "$WL/repo/.neural-network/project.yaml"
out="$(cd "$WL/repo" && bash "$PLUGIN/scripts/concurrency.sh" status)"
check "concurrency status shows the enforced In progress limit" "In progress 2" "$out"
check_absent "concurrency status hides an unenforced In review limit" "In review" "$out"
check "README says a full In review only warns in next" "only warns" "$(cat "$PLUGIN/README.md")"
check "concurrency skill says a full In review only warns in next" "only warns" "$(cat "$PLUGIN/skills/concurrency/SKILL.md")"
check "README states moves between counted statuses are never refused" "never refused" "$(cat "$PLUGIN/README.md")"
check "concurrency skill states moves between counted statuses are never refused" "never refused" "$(cat "$PLUGIN/skills/concurrency/SKILL.md")"
rm -rf "$WL"
