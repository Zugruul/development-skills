#!/usr/bin/env bash
# section-lint.sh -- sourced by run-tests.sh; do not run standalone.
# Static contracts: no Python, portable skill frontmatter, scripts the skills
# name exist, both manifests agree, the skills keep what makes a mock worth
# deciding on (accessibility, i18n, testability, both themes, the hub as the
# only answer channel), and the plugin knows nothing of any workflow, task
# tracker or other plugin.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/ui-design/tests/run-tests.sh" >&2; exit 2; }
echo "== lint: no python / frontmatter / skill contracts / standalone =="

py="$(find "$PLUGIN" -name '*.py' | sed "s#^$PLUGIN/##")"
check_rc "no Python files in the plugin" 0 "${#py}"
[[ -n "$py" ]] && echo "     $py"
shebang_py="$(grep -rlE '^#!.*python' "$PLUGIN" 2>/dev/null || true)"
check_rc "no Python scripts behind a shebang" 0 "${#shebang_py}"
pycall="$(grep -rnE 'python3? ' "$PLUGIN/skills" "$PLUGIN/scripts" "$PLUGIN/templates" --include='*.sh' --include='*.md' --include='*.html' || true)"
check_rc "no skill, script or template calls python" 0 "${#pycall}"
[[ -n "$pycall" ]] && echo "     $pycall"

for skill in ui-mode ui-options; do
    f="$PLUGIN/skills/$skill/SKILL.md"
    head="$(sed -n '2,/^---$/p' "$f" 2>/dev/null)"
    check "$skill: frontmatter name matches its directory" "name: $skill" "$head"
    check "$skill: has a description" "description: " "$head"
    desc="$(grep '^description: ' <<<"$head")"
    check_absent "$skill: description has no angle brackets (Codex rejects them)" "<" "$desc"
    check_absent "$skill: description has no closing angle brackets" ">" "$desc"
done
check_rc "every skill directory is covered above" 2 "$(find "$PLUGIN/skills" -name SKILL.md | wc -l | tr -d ' ')"

while IFS= read -r ref; do
    ok=0; [[ -f "$PLUGIN/${ref#../../}" ]] || ok=1
    check_rc "skills reference an existing file: $ref" 0 "$ok"
done < <(grep -rhoE '\.\./\.\./(scripts|templates)/[A-Za-z0-9_./-]+\.(sh|html)' "$PLUGIN/skills" | sort -u)
scripts="$(cd "$PLUGIN/scripts" && find . -name '*.sh' | sort | tr '\n' ' ')"
check "only the scripts the skills need" "./design-registry.sh ./src/hub-handler.sh ./src/repo-root.sh ./ui-hub.sh ./ui-mode.sh " "$scripts"
r=MISSING; [[ -s "$PLUGIN/scripts/vendor/axe.min.js" ]] && r=VENDORED
check "axe-core is vendored with the plugin" VENDORED "$r"

v1="$(jq -r .version "$PLUGIN/.claude-plugin/plugin.json")"
v2="$(jq -r .version "$PLUGIN/.codex-plugin/plugin.json")"
check "claude and codex manifests carry the same version" "$v1" "$v2"
check "claude manifest names the plugin" "ui-design" "$(jq -r .name "$PLUGIN/.claude-plugin/plugin.json")"
check "codex manifest names the plugin" "ui-design" "$(jq -r .name "$PLUGIN/.codex-plugin/plugin.json")"
check "codex manifest points at the skills" "./skills/" "$(jq -r .skills "$PLUGIN/.codex-plugin/plugin.json")"
check_rc "no plugin dependencies declared" 0 "$(jq '.dependencies // [] | length' "$PLUGIN/.claude-plugin/plugin.json")"

# Standalone: no workflow, task tracker, spec or other plugin.
leak="$(grep -rnoiE 'spec-workflow|build-next|implement-task|refine-task-ui|seed-board|board\.sh|\.neural-network|project\.yaml|methodology\.|iterativeUI|design-registry\.py|ui-hub\.py|herdr|remote-compute|peer-review|gh issue|gh pr|__ISSUE_URL__|__TASK_ID__|__TASK_TITLE__|issue comment|the task issue|board issue|"issue":|for-issue|staleness|UNAPPLIED' "$PLUGIN" --include='*.md' --include='*.sh' --include='*.json' --include='*.html' --exclude-dir=tests --exclude-dir=vendor || true)"
check_rc "no workflow, task tracker or other plugin is known to ui-design" 0 "${#leak}"
[[ -n "$leak" ]] && echo "$leak" | head -20 | sed 's/^/     /'

uo="$(cat "$PLUGIN/skills/ui-options/SKILL.md" 2>/dev/null)"
um="$(cat "$PLUGIN/skills/ui-mode/SKILL.md" 2>/dev/null)"
check "ui-mode: toggles through the script" 'bash "../../scripts/ui-mode.sh" status' "$um"
check "ui-mode: hands option pages to ui-options" "ui-options" "$um"
check "ui-options: checks the mode first" 'bash "../../scripts/ui-mode.sh" status' "$uo"
check "ui-options: delivery is the hub, never an Artifact" "never a claude.ai Artifact" "$uo"
check "ui-options: 2-4 genuinely different options" "2–4 genuinely different options" "$uo"
check "ui-options: mockups use the target's real canvas" "REAL canvas, at true scale" "$uo"
# shellcheck disable=SC2016  # literal SKILL.md text
check "ui-options: pages are written repo-root-relative" 'ROOT=$(git rev-parse --show-toplevel)' "$uo"
check "ui-options: copies the template" '"../../templates/ui-options.html"' "$uo"
check "ui-options: both themes and contrast" "Both themes, contrast + a11y" "$uo"
check "ui-options: real semantics" "REAL semantics" "$uo"
check "ui-options: testability via data-testid" "data-testid" "$uo"
check "ui-options: WCAG target size" "WCAG 2.5.8" "$uo"
check "ui-options: input purpose" "WCAG 1.3.5" "$uo"
check "ui-options: axe-core served by the hub" "/vendor/axe.min.js" "$uo"
check "ui-options: headless gate in both themes" "?theme=dark" "$uo"
check "ui-options: never weakens the audit" "never worked around by deleting or weakening the audit" "$uo"
# shellcheck disable=SC2016  # literal SKILL.md text
check "ui-options: i18n with en, pt and es" '`en` + `pt` + `es`' "$uo"
check "ui-options: i18n markers" "data-i18n" "$uo"
check "ui-options: tags the page with design-meta" 'id="design-meta"' "$uo"
check "ui-options: reuses registry tags" 'design-registry.sh" index' "$uo"
check "ui-options: hub through the script" 'bash "../../scripts/ui-hub.sh"' "$uo"
check "ui-options: arms a watcher on every ask" "arm the Send-watcher" "$uo"
check "ui-options: answers are scoped to the round id" "answers --consume --id" "$uo"
check "ui-options: a11y fix requests are not a decision" "### A11y fixes requested" "$uo"
check "ui-options: records the pick" 'design-registry.sh" pick' "$uo"
check "ui-options: no Suggested badge" 'Do **not** badge any option as "Suggested"' "$uo"
check "ui-options: element notes stay scoped" "Element notes:" "$uo"
check "ui-options: other skills may call it" "Called by another skill" "$uo"
# the way back into the session is each client's own command, and is omitted, never invented
# shellcheck disable=SC2016  # the literal SKILL.md prose, not an expansion
check "ui-options: Claude Code's resume command" '`claude --resume <the value of CLAUDE_CODE_SESSION_ID>`' "$uo"
# shellcheck disable=SC2016
check "ui-options: Codex's resume command" '`codex resume <the value of CODEX_THREAD_ID>`' "$uo"
check "ui-options: OpenCode gives its shell no session id" "OpenCode gives its shell no session id" "$uo"
check "ui-options: omits the resume sentence when there is no session id" "replace the whole resume sentence with nothing" "$uo"
check "ui-options: the watcher is the hub's own wait" '$HUB wait --id' "$uo"
check "ui-options: a fallback where no background command wakes the agent" "Codex and OpenCode: no finished background command starts a new turn" "$uo"
check_absent "template: no client's command is built in" "claude --resume" "$(cat "$PLUGIN/templates/ui-options.html")"

tpl="$(cat "$PLUGIN/templates/ui-options.html" 2>/dev/null)"
for ph in __DESIGN_ID__ __DESIGN_TITLE__ __RESUME_COMMAND__ __OPTION_ID__ __OPTION_NAME__ __OPTION_SUMMARY__ __ASPECT_KEYWORD__; do
    check "template: placeholder $ph" "$ph" "$tpl"
done
check "template: loads axe-core from the hub" "sc.src = '/vendor/axe.min.js'" "$tpl"
check "template: posts the answer to the hub" "fetch('/api/answer'" "$tpl"
check "template: keeps the turn-off hint" ".claude/ITERATIVE_UI_OFF" "$tpl"
check "template: theme and language via URL for headless checks" "?theme=light|dark and ?lang=xx" "$tpl"
check "template: the selection heading" "### UI selection — __DESIGN_ID__" "$tpl"
check "template: the a11y fix heading" "### A11y fixes requested — __DESIGN_ID__" "$tpl"
