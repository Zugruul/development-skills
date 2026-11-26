#!/usr/bin/env bash
# section-lint.sh -- sourced by run-tests.sh; do not run standalone.
# Static contracts: frontmatter, no Python, every referenced script exists, every shipped
# pattern and role is valid, the plugin stands on herdr alone, and the skills keep the rules.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }
echo "== lint: frontmatter / scripts / patterns / roles / standalone =="

for skill in orchestrate display; do
    f="$PLUGIN/skills/$skill/SKILL.md"
    head="$(sed -n '2,/^---$/p' "$f" 2>/dev/null)"
    check "$skill: frontmatter name matches its directory" "name: $skill" "$head"
    desc="$(grep '^description: ' <<<"$head")"
    check "$skill: has a description" "description: " "$desc"
    check_absent "$skill: description has no angle brackets (Codex rejects them)" "<" "$desc"
    check_absent "$skill: description has no closing angle brackets" ">" "$desc"
done
check_rc "every skill directory is covered above" 2 "$(find "$PLUGIN/skills" -name SKILL.md | wc -l | tr -d ' ')"
check "orchestrate: checks it is inside Herdr first" 'bash "../../scripts/check.sh"' "$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"

py="$(find "$PLUGIN" -name '*.py' | sed "s#^$PLUGIN/##")"
check_rc "no Python files in the plugin" 0 "${#py}"
while IFS= read -r ref; do
    ok=0; [[ -f "$PLUGIN/scripts/$ref" ]] || ok=1
    check_rc "skills name an existing script: $ref" 0 "$ok"
done < <(grep -rhoE '(\.\./\.\./scripts/|`)[a-z-]+\.sh' "$PLUGIN/skills" | sed -E 's#^(\.\./\.\./scripts/|`)##' | sort -u)
for p in "$PLUGIN"/patterns/*.yaml; do
    check "shipped pattern is valid: $(basename "$p")" "PATTERN OK" "$(XDG_CONFIG_HOME=/nonexistent bash "$PLUGIN/scripts/check-pattern.sh" "$p" 2>&1)"
done
for r in "$PLUGIN"/roles/*.md; do
    front="$(awk 'NR==1 && /^---$/ {f=1; next} f && /^---$/ {exit} f' "$r" | yq -o=json '.' 2>/dev/null)"
    name="$(basename "$r" .md)"
    check "role $name: frontmatter name matches the file" "$name" "$(jq -r '.name // ""' <<<"$front")"
    check "role $name: access is read or write" "ok" "$(jq -r 'if (.access | IN("read", "write")) then "ok" else "bad" end' <<<"$front")"
    for s in "## Objective" "## Boundaries" "## Output" "## Ask" "## End" "NODE {node} RESULT:"; do
        check "role $name: has '$s'" "$s" "$(cat "$r")"
    done
done

orch="$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
for dep in worktree agent prompt listen; do
    check "orchestrate: uses the herdr $dep skill" "herdr:$dep" "$orch"
done
check "orchestrate: lane files are written only by lane.sh" "written **only** by \`lane.sh\`" "$orch"
check "orchestrate: never trusts done" "Never trust \"done\" from an agent" "$orch"
check "orchestrate: retries only through lane.sh" "Retry only through \`lane.sh retry\`" "$orch"
check "orchestrate: asks before anything outside the lane" "**Ask before** marking a pull request ready" "$orch"
check "orchestrate: never merges" "**Never** merge" "$orch"
check "orchestrate: read-only nodes are checked" "Any change fails the node" "$orch"
check "display: only reads" "This skill only reads" "$(cat "$PLUGIN/skills/display/SKILL.md")"

leak="$(grep -rnoiE 'herdr-simple-orchestrate|orchestrate-code-reviews|spec-workflow|herdr-development-skills|\.neural-network|board\.sh|herdr_ctl\.py' "$PLUGIN" --include='*.md' --include='*.sh' --include='*.yaml' --include='*.json' --exclude-dir=tests || true)"
check_rc "the plugin stands on herdr alone" 0 "${#leak}"
[[ -n "$leak" ]] && echo "     $leak"
v1="$(jq -r .version "$PLUGIN/.claude-plugin/plugin.json")"
v2="$(jq -r .version "$PLUGIN/.codex-plugin/plugin.json")"
check "claude and codex manifests carry the same version" "$v1" "$v2"
check "the claude manifest requires herdr only" '["herdr"]' "$(jq -c .dependencies "$PLUGIN/.claude-plugin/plugin.json")"
