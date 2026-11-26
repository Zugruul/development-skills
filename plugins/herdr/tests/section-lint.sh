#!/usr/bin/env bash
# section-lint.sh -- sourced by run-tests.sh; do not run standalone.
# Static contracts: no Python, every skill has portable frontmatter and checks it runs
# inside Herdr, the skills keep the hard-won Herdr rules, and the plugin only teaches
# Herdr: no orchestrator workflow and no knowledge of any other plugin.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr/tests/run-tests.sh" >&2; exit 2; }
echo "== lint: no python / frontmatter / skill contracts / pure herdr =="

py="$(find "$PLUGIN" -name '*.py' | sed "s#^$PLUGIN/##")"
check_rc "no Python files in the plugin" 0 "${#py}"
[[ -n "$py" ]] && echo "     $py"
shebang_py="$(grep -rlE '^#!.*python' "$PLUGIN" 2>/dev/null || true)"
check_rc "no Python scripts behind a shebang" 0 "${#shebang_py}"

for skill in worktree agent prompt listen status; do
    f="$PLUGIN/skills/$skill/SKILL.md"
    head="$(sed -n '2,/^---$/p' "$f" 2>/dev/null)"
    check "$skill: frontmatter name matches its directory" "name: $skill" "$head"
    check "$skill: has a description" "description: " "$head"
    desc="$(grep '^description: ' <<<"$head")"
    check_absent "$skill: description has no angle brackets (Codex rejects them)" "<" "$desc"
    check_absent "$skill: description has no closing angle brackets" ">" "$desc"
    check "$skill: checks it is inside Herdr first" 'bash "../../scripts/check.sh"' "$(cat "$f")"
done
check_rc "every skill directory is covered above" 5 "$(find "$PLUGIN/skills" -name SKILL.md | wc -l | tr -d ' ')"

scripts="$(cd "$PLUGIN/scripts" && find . -name '*.sh' | sort | tr '\n' ' ')"
check "only the scripts Herdr cannot do in one call" "./check-path.sh ./check.sh ./listen.sh ./src/herdr.sh ./src/require.sh ./start.sh " "$scripts"
while IFS= read -r ref; do
    ok=0; [[ -f "$PLUGIN/skills/x/$ref" || -f "$PLUGIN/${ref#../../}" ]] || ok=1
    check_rc "skills reference an existing script: $ref" 0 "$ok"
done < <(grep -rhoE '\.\./\.\./scripts/[a-z/-]+\.sh' "$PLUGIN/skills" | sort -u)

wt="$(cat "$PLUGIN/skills/worktree/SKILL.md")"
check "worktree: checks before creating" "## 2. Check (read-only), then ask" "$wt"
check "worktree: the label has no spaces" "hyphen-separated group of letters and digits with no spaces" "$wt"
check "worktree: asks the user before creating" "Ask the user" "$wt"
for flag in --cwd --branch --base --path --label; do
    check "worktree: passes $flag explicitly" "$flag" "$wt"
done
check "worktree: follows the repository's location rule" "location rule" "$wt"
check "worktree: the target repository is the git toplevel of the checkout being changed" "git -C <target> rev-parse --show-toplevel" "$wt"
check "worktree: only the target's own instructions set the location" "only from that repository's own instructions" "$wt"
check "worktree: an enclosing repository's rule never applies to a nested clone" "never applies to a nested standalone clone" "$wt"
check "worktree: the path is checked against other repositories" 'bash "../../scripts/check-path.sh" --target <target> --path <path>' "$wt"
check "worktree: a failed create is checked before a retry" "run \`herdr worktree list\` before any retry" "$wt"
check_absent "worktree: never grants repository trust by itself" "create --trust-repository" "$wt"
ag="$(cat "$PLUGIN/skills/agent/SKILL.md")"
check "agent: starts through the retrying script" 'bash "../../scripts/start.sh"' "$ag"
check "agent: explains the busy pane" "agent_pane_busy" "$ag"
check "agent: start and prompt are separate steps" "separate steps" "$ag"
pr="$(cat "$PLUGIN/skills/prompt/SKILL.md")"
check "prompt: uses Herdr's own wait" "herdr agent prompt <target> \"<prompt>\" --wait" "$pr"
check "prompt: never resubmits blindly" "never resend" "$pr"
check "prompt: a blocked agent got nothing" "**nothing was sent**" "$pr"
check "prompt: blocked dialogs need the user" "Ask the user" "$pr"
li="$(cat "$PLUGIN/skills/listen/SKILL.md")"
check "listen: reads the visible screen" "--source visible" "$li"
check "listen: nothing notifies the listener" "Nothing notifies" "$li"
check "listen: asks which agent when ambiguous" "which agent" "$li"
check "listen: a timeout proves nothing" "timeout" "$li"
check "listen: one agent uses herdr agent wait" "herdr agent wait <target>" "$li"
check "listen: several agents use the script" 'bash "../../scripts/listen.sh"' "$li"
st="$(cat "$PLUGIN/skills/status/SKILL.md")"
check "status: still read-only" "This skill only reads." "$st"
check "status: the lists are pasted in a code block" "inside one fenced code block" "$st"
check "status: lists carry no paths" "No paths and no pane or tab columns" "$st"

# Pure Herdr: no orchestrator workflow, no other plugin.
orch="$( { grep -rnoiE 'orchestrat' "$PLUGIN/skills" "$PLUGIN/scripts"; grep -rnoE 'report\.md|NEEDS YOU' "$PLUGIN/skills" "$PLUGIN/scripts"; } || true)"
check_rc "no orchestrator workflow in the herdr skills or scripts" 0 "${#orch}"
[[ -n "$orch" ]] && echo "     $orch"
leak="$(grep -rnoiE 'spec-workflow|build-next|implement-task|peer-review|remote-compute|\.neural-network|board\.sh|herdr-development-skills|herdr-simple-orchestrate|herdr-graph-engineering' "$PLUGIN" --include='*.md' --include='*.sh' --include='*.json' --exclude-dir=tests || true)"
check_rc "no other plugin is known to the herdr plugin" 0 "${#leak}"
[[ -n "$leak" ]] && echo "     $leak"

v1="$(jq -r .version "$PLUGIN/.claude-plugin/plugin.json")"
v2="$(jq -r .version "$PLUGIN/.codex-plugin/plugin.json")"
check "claude and codex manifests carry the same version" "$v1" "$v2"
