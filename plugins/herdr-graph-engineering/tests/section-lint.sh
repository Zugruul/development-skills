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
dsp="$(cat "$PLUGIN/skills/display/SKILL.md")"
check "display: toggles the Herdr panel" "herdr plugin action invoke herdr-graph-engineering.graph.toggle" "$dsp"
check "display: falls back to text" 'bash "../../scripts/status.sh" --text' "$dsp"
check "display: never edits the user's Herdr config" "never edit the user's Herdr config yourself" "$dsp"
check "orchestrate: offers the panel install and asks first" "run it only if the user says yes" "$orch"
check "orchestrate: keeps the sidebar tokens current" 'status.sh" --tokens' "$orch"
check "orchestrate: panel answers count as chat answers" "Answer for lane <lane>" "$orch"

echo "== lint: reviews keep the grouped format =="
rb="$(cat "$PLUGIN/references/review-brief.md")"
rs="$(cat "$PLUGIN/references/review-summary.md")"
check "orchestrate: one COMMENT review per pull request" "**one \`COMMENT\` review** holding every new inline finding" "$orch"
check "orchestrate: the summary is the review body" "whose **body is the summary**" "$orch"
check "orchestrate: a finding found twice is posted once" "**a finding two reviewers found is posted once**" "$orch"
check "orchestrate: the body is put in with a PUT" "gh api -X PUT repos/<owner>/<repo>/pulls/<n>/reviews/<review id>" "$orch"
check "orchestrate: the posted review is verified" "its state is still \`COMMENTED\`" "$orch"
check "summary: the count line" "**<N> findings:**" "$rs"
check "summary: the numbered findings table" "| # | Severity | Finding | Where |" "$rs"
check "summary: worth a look" "Worth a look (not confirmed, not posted inline)" "$rs"
check "summary: checked and found correct" "Checked and found correct" "$rs"
check "summary: all fix prompts in one block" "Prompt for AI Agents (all findings)" "$rs"
check "brief: the proof standard" "## Proof standard" "$rb"
check "brief: the draft format" "## Draft format" "$rb"
check "brief: the comment format" "## Comment format" "$rb"
check "brief: never approve or merge" "Never mark a pull request ready, approve it, request changes, merge it or push to its branch" "$rb"
check "poster: one COMMENT review with the placeholder body" "with the body \`Review summary to follow.\`" "$(cat "$PLUGIN/roles/poster.md")"

leak="$(grep -rnoiE 'herdr-simple-orchestrate|orchestrate-code-reviews|spec-workflow|herdr-development-skills|\.neural-network|board\.sh|herdr_ctl\.py' "$PLUGIN" --include='*.md' --include='*.sh' --include='*.yaml' --include='*.json' --exclude-dir=tests || true)"
check_rc "the plugin stands on herdr alone" 0 "${#leak}"
[[ -n "$leak" ]] && echo "     $leak"
v1="$(jq -r .version "$PLUGIN/.claude-plugin/plugin.json")"
v2="$(jq -r .version "$PLUGIN/.codex-plugin/plugin.json")"
check "claude and codex manifests carry the same version" "$v1" "$v2"
check "the claude manifest requires herdr only" '["herdr"]' "$(jq -c .dependencies "$PLUGIN/.claude-plugin/plugin.json")"

echo "== lint: the fast pattern =="
fast="$PLUGIN/patterns/fast.yaml"
check "fast: shipped and valid" "PATTERN OK" "$(XDG_CONFIG_HOME=/nonexistent bash "$PLUGIN/scripts/check-pattern.sh" "$fast" 2>&1)"
fjson="$(yq -o=json '.' "$fast" 2>/dev/null)"
check "fast: the lean role implements" "fast-implementer" "$(jq -r '.nodes.impl.agent // ""' <<<"$fjson")"
check "fast: the draft pull request opens right after impl" "draft impl" "$(jq -r '[.nodes.pr.pr, (.nodes.pr.needs // [] | join(","))] | join(" ")' <<<"$fjson")"
check "fast: the gate runs after the pull request is open" "pr" "$(jq -r '.nodes.tests.needs // [] | join(",")' <<<"$fjson")"
check "fast: a failing gate goes back to the implementer" "impl fail" "$(jq -r '[.nodes.tests.retry.to, .nodes.tests.retry.on] | join(" ")' <<<"$fjson")"
check "fast: done is the gate and the draft pull request" '[{"gate":"tests"},"draft-pr"]' "$(jq -c '.done' <<<"$fjson")"
fr="$(cat "$PLUGIN/roles/fast-implementer.md" 2>/dev/null)"
check "fast role: the smallest fix" "smallest fix" "$fr"
check "fast role: a focused test or assertion" "focused test or assertion" "$fr"
check "fast role: no refactors or long exploration" "No refactors" "$fr"
check "fast role: never pushes or opens the pull request" "Do not push, open a pull request" "$fr"
router="$(cat "$PLUGIN/references/router.md")"
check "router: routes urgent work to fast" "| \`fast\` |" "$router"
check "router: names the fast triggers" "hotfix" "$router"
check "router: never picks fast by default" "Never pick \`fast\` by default" "$router"
check "router: fast has a feat branch" "Changing patterns (\`solo\`, \`pair\`, \`fast\`)" "$router"
check "README: lists fast" "| \`fast\` |" "$(cat "$PLUGIN/README.md")"
check "README: lists the pr node" "\`pr\`" "$(cat "$PLUGIN/README.md")"
check "orchestrate: runs a pr node" "**pr node**" "$orch"
check "orchestrate: a pr node pushes to the open pull request" "pushes to the pull request that is already open" "$orch"
