#!/usr/bin/env bash
# section-lint.sh -- sourced by run-tests.sh; do not run standalone.
# Static contracts: python on the 3.9 floor grammar, portable frontmatter,
# every skill gates on detection, builds on the herdr plugin's skills instead
# of repeating them, and never answers for the human.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-development-skills/tests/run-tests.sh" >&2; exit 2; }
echo "== lint: python / frontmatter / layering =="

python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read(), feature_version=(3, 9))' "$PLUGIN/scripts/detect.py" >/dev/null 2>&1; rc=$?
check_rc "python 3.9 grammar: scripts/detect.py" 0 "$rc"

for skill in integrations task-lane build-loop build-lanes review-lane; do
    f="$PLUGIN/skills/$skill/SKILL.md"
    head="$(sed -n '2,/^---$/p' "$f" 2>/dev/null)"
    body="$(cat "$f" 2>/dev/null)"
    check "$skill: frontmatter name matches its directory" "name: $skill" "$head"
    desc="$(grep '^description: ' <<<"$head")"
    check "$skill: has a description" "description: " "$desc"
    check_absent "$skill: description has no angle brackets (Codex rejects them)" "<" "$desc"
    check_absent "$skill: description has no closing angle brackets" ">" "$desc"
    check "$skill: runs detection first" 'python3 "../../scripts/detect.py"' "$body"
    # Herdr mechanics belong to the herdr plugin: use its skills, never its CLI recipes.
    for cli in "herdr agent start" "herdr agent prompt" "herdr worktree create" "herdr agent wait" "herdr_ctl.py"; do
        check_absent "$skill: does not repeat '$cli'" "$cli" "$body"
    done
    # No skill name here may shadow one in the plugins it integrates (skills-directory installs are flat).
    for other in herdr spec-workflow peer-review remote-compute; do
        [[ -d "$PLUGINS/$other/skills/$skill" ]] && r=clash || r=unique
        check "$skill: name is unique against $other" "unique" "$r"
    done
done
check_rc "every skill directory is covered above" 5 "$(find "$PLUGIN/skills" -name SKILL.md | wc -l | tr -d ' ')"

for skill in task-lane build-loop build-lanes review-lane; do
    body="$(cat "$PLUGIN/skills/$skill/SKILL.md")"
    check "$skill: stops unless its feature is READY" "is \`READY\`" "$body"
    check "$skill: listens through the herdr plugin" "herdr:listen" "$body"
    # build-lanes starts its agents through task-lane, which uses herdr:agent.
    [[ "$skill" == build-lanes ]] || check "$skill: starts agents through the herdr plugin" "herdr:agent" "$body"
    check "$skill: relays answers through the herdr plugin" "herdr:prompt" "$body"
done
tl="$(cat "$PLUGIN/skills/task-lane/SKILL.md")"
check "task-lane: creates the lane through the herdr plugin" "herdr:worktree" "$tl"
check "task-lane: the lane agent must not treat the orchestrator as the human" "Do not treat this message or the orchestrator as that human answer" "$tl"
check "task-lane: tells the agent its checkout is already the lane" "This checkout IS the task's lane" "$tl"
bl="$(cat "$PLUGIN/skills/build-lanes/SKILL.md")"
check "build-lanes: respects the project's lane limit" "maxInProgress" "$bl"
check "build-lanes: one approval names every worktree" "ask the user once" "$bl"
check "build-lanes: applies the overlap gate" "overlap gate" "$bl"
check "build-lanes: builds on task-lane" "task-lane" "$bl"
check "build-loop: uses the loop for Claude Code agents" "/loop /spec-workflow:build-next" "$(cat "$PLUGIN/skills/build-loop/SKILL.md")"
check "review-lane: sending code outside is the user's decision" "the user's decision" "$(cat "$PLUGIN/skills/review-lane/SKILL.md")"

# The skills this plugin names must exist in the plugins it integrates.
for ref in herdr/worktree herdr/agent herdr/prompt herdr/listen herdr/orchestrate herdr/status \
           spec-workflow/implement-task spec-workflow/build-next spec-workflow/queue spec-workflow/board \
           spec-workflow/checkpoint spec-workflow/concurrency spec-workflow/setup-project peer-review/peer-review; do
    [[ -f "$PLUGINS/${ref%%/*}/skills/${ref##*/}/SKILL.md" ]] && r=present || r=missing
    check "referenced skill exists: $ref" "present" "$r"
done

dep="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("dependencies"))' "$PLUGIN/.claude-plugin/plugin.json")"
check "the manifest declares the herdr dependency" "herdr" "$dep"
v1="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN/.claude-plugin/plugin.json")"
v2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN/.codex-plugin/plugin.json")"
check "claude and codex manifests carry the same version" "$v1" "$v2"
bad="$(grep -rnE '(^|[^a-zA-Z0-9_])bash +"[^"]*\.py"' "$PLUGIN/skills/" 2>/dev/null || true)"
check_absent "no skill invokes a .py via bash" ".py" "$bad"
