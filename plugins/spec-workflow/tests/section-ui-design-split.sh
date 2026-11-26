#!/usr/bin/env bash
# section-ui-design-split.sh -- sourced by run-tests.sh; do not run standalone.
# Contract: the runner already defines set -uo pipefail and has sourced
# _lib.sh (check/check_rc/check_absent/lifecycle_start/_rand_port) and set
# HERE/PLUGIN/FIX/fails/flaky before sourcing this file.
#
# Mocking and deciding UI moved to the standalone ui-design plugin. spec-workflow
# keeps the workflow side: the methodology.iterativeUI switch, the issue
# channel, refine-task-ui, the design registry it gates on, and the move-to-review
# guard. It calls ui-design by skill name when installed, never by path, and
# decides UI itself when ui-design is absent.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/spec-workflow/tests/run-tests.sh" >&2; exit 2; }
echo "== ui-design split: spec-workflow keeps the workflow, calls ui-design by name =="

for gone in skills/ui-mode skills/ui-options scripts/ui-mode.sh scripts/ui-hub.py templates/ui-options.html scripts/vendor/axe.min.js tests/section-ui-hub.sh; do
    r=GONE; [[ -e "$PLUGIN/$gone" ]] && r=PRESENT
    check "moved to ui-design, no copy left: $gone" GONE "$r"
done
for kept in skills/refine-task-ui/SKILL.md scripts/design-registry.py scripts/design-registry-preflight.sh scripts/iterative-ui.sh skills/build-next/references/ui-design.md; do
    r=MISSING; [[ -f "$PLUGIN/$kept" ]] && r=PRESENT
    check "workflow side stays in spec-workflow: $kept" PRESENT "$r"
done

# Never a path into another plugin.
leak="$(grep -rnE 'plugins/ui-design|\.\./ui-design|ui-design/scripts|scripts/ui-hub\.(py|sh)|scripts/ui-mode\.sh|templates/ui-options\.html' "$PLUGIN/skills" "$PLUGIN/scripts" "$PLUGIN/hooks" "$PLUGIN/AGENTS.md" "$PLUGIN/README.md" 2>/dev/null || true)"
check_rc "spec-workflow names no ui-design path and no moved script" 0 "${#leak}"
[[ -n "$leak" ]] && echo "$leak" | head -10 | sed 's/^/     /'

ref="$(cat "$PLUGIN/skills/build-next/references/ui-design.md" 2>/dev/null)"
check "reference: calls the ui-design skills by name" "ui-design:ui-options" "$ref"
check "reference: says how to tell ui-design is installed" "is installed" "$ref"
check "reference: decides UI itself when ui-design is absent" "decide the UI yourself" "$ref"
check "reference: the project switch stays in spec-workflow" "methodology.iterativeUI" "$ref"
check "reference: checks the mode through its own reader" 'bash "../../scripts/iterative-ui.sh"' "$ref"
check "reference: the design id is the task id" "design id" "$ref"
check "reference: adds the board issue to design-meta (the move-to-review guard reads it)" '"issue": <N>' "$ref"
check "reference: posts the hub pointer on the issue" "board.sh comment" "$ref"
check "reference: reads UI selections from the issue too" "### UI selection" "$ref"
check "reference: finds earlier decisions before UI work" "design-registry.py\" find --tags" "$ref"
check "reference: records applied once merged" "design-registry.py\" applied" "$ref"
check "reference: blocked-on-human stops the iteration" "blocked-on-human" "$ref"

for s in build-next implement-task refine-task-ui; do
    body="$(cat "$PLUGIN/skills/$s/SKILL.md")"
    check "$s points at the ui-design reference" "references/ui-design.md" "$body"
    check "$s calls ui-design by skill name" "ui-design:" "$body"
done
rt="$(cat "$PLUGIN/skills/refine-task-ui/SKILL.md")"
check "refine-task-ui: stops when ui-design is not installed" "ui-design plugin is not installed" "$rt"
check_absent "refine-task-ui: no moved script" "ui-hub.py" "$rt"

# iterative-ui.sh: spec-workflow's own reader of its switch and the shared flag.
IU="$PLUGIN/scripts/iterative-ui.sh"
_iu="$(mktemp -d)"; ( cd "$_iu" && git init -q . && git commit -q --allow-empty -m init )
_iu="$(cd -P "$_iu" && pwd -P)"
out="$(cd "$_iu" && bash "$IU" 2>&1)"
check "iterative-ui: ON by default" "ON (UI decisions go to the human through the ui-design plugin when it is installed)" "$out"
mkdir -p "$_iu/.claude"; touch "$_iu/.claude/ITERATIVE_UI_OFF"
out="$(cd "$_iu" && bash "$IU" 2>&1)"
check "iterative-ui: the shared local flag turns it off" "OFF (local flag $_iu/.claude/ITERATIVE_UI_OFF" "$out"
rm -f "$_iu/.claude/ITERATIVE_UI_OFF"
mkdir -p "$_iu/.neural-network"; cp "$FIX/valid.project.json" "$_iu/.neural-network/project.json"
python3 - "$_iu/.neural-network/project.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d.setdefault("methodology", {})["iterativeUI"] = False
json.dump(d, open(p, "w"))
PY
out="$(cd "$_iu" && bash "$IU" 2>&1)"
check "iterative-ui: methodology.iterativeUI=false is the project-wide off" "OFF (methodology.iterativeUI=false in the project config — project-wide)" "$out"
out="$(cd "$_iu" && bash "$PLUGIN/scripts/session-start.sh" 2>&1)"
check "session-start still reports the mode" "- Iterative UI mode: OFF (methodology.iterativeUI=false" "$out"
rm -rf "$_iu"
