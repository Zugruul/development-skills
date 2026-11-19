#!/usr/bin/env bash
# section-lint.sh -- sourced by run-tests.sh; do not run standalone.
# Static contracts: python compiles on the 3.9 floor grammar, every skill has
# portable frontmatter, the skills keep the hard-won Herdr rules, and the
# plugin stays standalone (no knowledge of the specialized plugins).
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr/tests/run-tests.sh" >&2; exit 2; }
echo "== lint: python / frontmatter / skill contracts / standalone =="

while IFS= read -r py; do
    out="$(python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), feature_version=(3, 9))' "$py" 2>&1)"; rc=$?
    check_rc "python 3.9 grammar: ${py#"$PLUGIN"/}" 0 "$rc"
    [[ $rc -ne 0 ]] && echo "     $out"
done < <(find "$PLUGIN/scripts" "$FIX/stub-herdr" -type f \( -name '*.py' -o -name herdr \) | sort)

for skill in worktree agent prompt listen orchestrate status; do
    f="$PLUGIN/skills/$skill/SKILL.md"
    head="$(sed -n '2,/^---$/p' "$f" 2>/dev/null)"
    check "$skill: frontmatter name matches its directory" "name: $skill" "$head"
    check "$skill: has a description" "description: " "$head"
    desc="$(grep '^description: ' <<<"$head")"
    check_absent "$skill: description has no angle brackets (Codex rejects them)" "<" "$desc"
    check_absent "$skill: description has no closing angle brackets" ">" "$desc"
    check "$skill: checks it is inside Herdr first" 'herdr_ctl.py" check' "$(cat "$f")"
done
check_rc "every skill directory is covered above" 6 "$(find "$PLUGIN/skills" -name SKILL.md | wc -l | tr -d ' ')"

wt="$(cat "$PLUGIN/skills/worktree/SKILL.md")"
check "worktree: plans before creating" "worktree-plan" "$wt"
check "worktree: asks the user before creating" "Ask the user" "$wt"
for flag in --cwd --branch --base --path; do
    check "worktree: passes $flag explicitly" "$flag" "$wt"
done
check "worktree: follows the repository's location rule" "location rule" "$wt"
check_absent "worktree: never grants repository trust by itself" "create --trust-repository" "$wt"
ag="$(cat "$PLUGIN/skills/agent/SKILL.md")"
check "agent: starts through the retrying helper" 'herdr_ctl.py" start' "$ag"
check "agent: explains the busy pane" "agent_pane_busy" "$ag"
check "agent: start and prompt are separate steps" "separate steps" "$ag"
pr="$(cat "$PLUGIN/skills/prompt/SKILL.md")"
check "prompt: never resubmits blindly" "never resend" "$pr"
check "prompt: blocked dialogs need the user" "Ask the user" "$pr"
li="$(cat "$PLUGIN/skills/listen/SKILL.md")"
check "listen: reads the visible screen" "--source visible" "$li"
check "listen: nothing notifies the orchestrator" "Nothing notifies" "$li"
check "listen: asks which agent when ambiguous" "which agent" "$li"
check "listen: a timeout proves nothing" "timeout" "$li"
orch="$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
for dep in worktree agent prompt listen status; do
    check "orchestrate: loads the $dep skill" "../$dep/SKILL.md" "$orch"
done

# Standalone: nothing in this plugin may know the specialized plugins.
leak="$(grep -rnoiE 'spec-workflow|build-next|implement-task|peer-review|remote-compute|\.neural-network|board\.sh' "$PLUGIN" --include='*.md' --include='*.py' --include='*.json' --exclude-dir=tests || true)"
check_rc "no specialized-plugin knowledge leaks into the herdr plugin" 0 "${#leak}"
[[ -n "$leak" ]] && echo "     $leak"

bad="$(grep -rnE '(^|[^a-zA-Z0-9_])bash +"[^"]*\.py"' "$PLUGIN/skills/" 2>/dev/null || true)"
check_absent "no skill invokes a .py via bash" ".py" "$bad"
v1="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN/.claude-plugin/plugin.json")"
v2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN/.codex-plugin/plugin.json")"
check "claude and codex manifests carry the same version" "$v1" "$v2"
