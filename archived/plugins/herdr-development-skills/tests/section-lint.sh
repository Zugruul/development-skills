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
        [[ -d "$PLUGINS/$other/skills/$skill" || -d "$PLUGINS/../../plugins/$other/skills/$skill" ]] && r=clash || r=unique
        check "$skill: name is unique against $other" "unique" "$r"
    done
done
check_rc "every skill directory is covered above" 5 "$(find "$PLUGIN/skills" -name SKILL.md | wc -l | tr -d ' ')"

for skill in task-lane build-loop build-lanes review-lane; do
    body="$(cat "$PLUGIN/skills/$skill/SKILL.md")"
    check "$skill: gates on its feature's state" "is \`READY\`" "$body"
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

# --- work without a task identifier: one shared procedure, three paths ---
ref="$(cat "$PLUGIN/references/task-source.md" 2>/dev/null)"
check "task-source: option 1 is named exactly" "**Run the workflow without a task**" "$ref"
check "task-source: option 2 is named exactly" "**Create a task for it**" "$ref"
check "task-source: option 3 is named exactly" "**Provide the task identifier**" "$ref"
check_rc "task-source: the question has exactly three options" 3 "$(grep -cE '^\| [0-9]+ \| \*\*' <<<"$ref")"
check "task-source: forbids extra or missing options" "Add nothing to the list and remove nothing from it" "$ref"
check "task-source: never guess, refuse or bypass" "Do not guess a task, do not refuse, and do not quietly drop to plain Herdr skills" "$ref"
check "task-source: once per piece, not per skill hop" "never once per skill hop" "$ref"
check "task-source: several pieces get one labelled question each" "each labelled with its piece" "$ref"
check "task-source: answers may differ per piece" "The answers may differ" "$ref"
check "task-source: skipped when an identifier was given" "The user gave its identifier" "$ref"
check "task-source: a standing answer covers the request" "A standing answer covers it" "$ref"
check "task-source: availability comes from detection" 'python3 "../../scripts/detect.py"' "$ref"
check "task-source: reads the TASK SOURCE block" "TASK SOURCE" "$ref"
check "task-source: no question with dead options" "do not ask a question with dead options" "$ref"
check "task-source: says why and continues with option 1" "continue with option 1" "$ref"
check "task-source: option 1 needs a complete brief" "the brief must come entirely from the user" "$ref"
for part in "**Goal**" "**Checkout**" "**Scope**" "**Done**" "**Report**"; do
    check "task-source: the no-task brief covers $part" "$part" "$ref"
done
check "task-source: a thin description is asked about, not invented" "ask the user for that one missing piece" "$ref"
check "task-source: option 2 goes through spec-workflow's intake" "spec-workflow \`create-inbound\` skill" "$ref"
check "task-source: option 2 never searches or creates issues itself" "Do not search or create issues yourself" "$ref"
check "task-source: option 2 shows the identifier" "tell the user the identifier" "$ref"
check "task-source: option 2 never falls back silently" "Do not fall back to option 1 silently" "$ref"
check "task-source: option 3 reads the task through the board skill" "spec-workflow \`board\` skill" "$ref"
check "task-source: option 3 never guesses a near match" "rather than guessing a near match" "$ref"
for skipped in "board status moves" "issue comments" "task-state record" "gate record tied to a task" "linking the pull request to an issue"; do
    check "task-source: the report names '$skipped' as skipped" "$skipped" "$ref"
done
check "task-source: skipped steps carry a fixed marker" "skipped (no task)" "$ref"
# Duplicated spec-workflow logic would show up as its scripts being called from here.
dup="$(grep -rnE 'board\.sh|similar\.py|gh issue|gh api' "$PLUGIN/skills" "$PLUGIN/references" || true)"
check_rc "no spec-workflow task logic is duplicated in this plugin" 0 "${#dup}"

for skill in task-lane build-lanes build-loop; do
    body="$(cat "$PLUGIN/skills/$skill/SKILL.md")"
    check "$skill: uses the shared task-source procedure" "../../references/task-source.md" "$body"
    check "$skill: handles a description instead of an identifier" "description" "$body"
done
check "task-lane: a given identifier is never questioned" "Do not ask." "$tl"
check "task-lane: runs on LIMITED too" "\`READY\` or \`LIMITED\`" "$tl"
check "task-lane: has a no-task lane" "## 7. The no-task lane" "$tl"
check "task-lane: the no-task lane touches no board skill" "Do not use the spec-workflow \`board\`, \`implement-task\` or \`build-next\` skills for this piece" "$tl"
check "task-lane: the no-task agent is told there is no task" "This work has no board task." "$tl"
check "task-lane: the no-task agent must not touch the board" "do not read, create, move or comment on any board item or issue" "$tl"
for part in "Goal:" "Checkout:" "In scope:" "Done means:" "When you stop, report:"; do
    check "task-lane: the no-task brief template has '$part'" "$part" "$tl"
done
check "task-lane: the no-task lane still goes through herdr:worktree" "### 7.2 Lane worktree" "$tl"
check "task-lane: the no-task report names the skipped steps" "skipped (no task)" "$tl"
check "task-lane: a refusal for lacking a task returns to options 2 and 3" "offer options 2 and 3 again" "$tl"
check "build-lanes: asks per piece, answers may differ" "one question per piece" "$bl"
check "build-lanes: a standing answer covers the request" "standing answer" "$bl"
check "build-lanes: hands the task source on so nobody is asked twice" "so the user is not asked again" "$bl"
check "build-lanes: no-task lanes use no board slot" "do not occupy a \`maxInProgress\` slot" "$bl"
check "build-lanes: runs on LIMITED too" "\`READY\` or \`LIMITED\`" "$bl"
bo="$(cat "$PLUGIN/skills/build-loop/SKILL.md")"
check "build-loop: a bare loop request asks nothing" "needs no task and no question" "$bo"
check "build-loop: described work goes to a single lane" "hand the piece with its task source to the \`task-lane\` skill" "$bo"
check "build-loop: never starts the loop instead of described work" "Do not start the loop as a substitute" "$bo"
rv="$(cat "$PLUGIN/skills/review-lane/SKILL.md")"
check "review-lane: needs a lane, not a task" "A review needs a lane, not a task" "$rv"
check "review-lane: finds a lane that has no task" "for a lane without a task, by branch, worktree, workspace label or agent name" "$rv"
check_absent "review-lane: does not ask the task-source question" "task-source.md" "$rv"
ig="$(cat "$PLUGIN/skills/integrations/SKILL.md")"
check "integrations: explains the LIMITED state" "\`LIMITED\`" "$ig"
check "integrations: explains the TASK SOURCE block" "TASK SOURCE" "$ig"

# The skills this plugin names must exist in the plugins it integrates.
for ref in herdr/worktree herdr/agent herdr/prompt herdr/listen herdr-simple-orchestrate/orchestrate herdr/status \
           spec-workflow/implement-task spec-workflow/build-next spec-workflow/queue spec-workflow/board \
           spec-workflow/checkpoint spec-workflow/concurrency spec-workflow/setup-project spec-workflow/create-inbound peer-review/peer-review; do
    # the integrated plugins are split between the archive and the repository's root plugins/
    f="${ref%%/*}/skills/${ref##*/}/SKILL.md"
    [[ -f "$PLUGINS/$f" || -f "$PLUGINS/../../plugins/$f" ]] && r=present || r=missing
    check "referenced skill exists: $ref" "present" "$r"
done

dep="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("dependencies"))' "$PLUGIN/.claude-plugin/plugin.json")"
check "the manifest declares the herdr dependency" "herdr" "$dep"
v1="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN/.claude-plugin/plugin.json")"
v2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN/.codex-plugin/plugin.json")"
check "claude and codex manifests carry the same version" "$v1" "$v2"
bad="$(grep -rnE '(^|[^a-zA-Z0-9_])bash +"[^"]*\.py"' "$PLUGIN/skills/" 2>/dev/null || true)"
check_absent "no skill invokes a .py via bash" ".py" "$bad"

echo "== lint: lane names =="
tl="$(cat "$PLUGIN/skills/task-lane/SKILL.md")"
check "task-lane: names come from the helper" "python3 \"../../scripts/lane_name.py\" --source" "$tl"
check "task-lane: the no-task lane uses the helper without a source" "lane_name.py\" --desc" "$tl"
check "task-lane: task branch rule" "feat/<taskid>-<desc>" "$tl"
check "task-lane: no-task branch rule" "feat/<desc>" "$tl"
check "task-lane: the label carries the source tag" "<TAG>-<taskid>-<desc>" "$tl"
check "task-lane: nothing splits a name on hyphens" "never take a branch or label apart" "$tl"
check_absent "task-lane: the branch no longer comes from branchPattern" "\`branchPattern\` filled with" "$tl"
# The tags live in one mapping, and the standalone herdr plugin knows label shape, not task sources.
check_rc "the source tags are defined in one place" 1 "$(grep -rl 'SOURCE_TAGS = ' "$PLUGIN/scripts" | wc -l | tr -d ' ')"
check_rc "herdr does not know task sources or tags" 0 "$(grep -rlE 'clickup|ClickUp|SOURCE_TAGS|GH-[0-9]|CU-[a-z0-9]' "$PLUGINS/herdr/scripts" "$PLUGINS/herdr/skills" 2>/dev/null | wc -l | tr -d ' ')"

echo "== lint: orchestrator report lines =="
rl="$(cat "$PLUGIN/references/report-lines.md" 2>/dev/null)"
for line in "task:" "gate:" "board:" "skipped (no task):"; do
    check "report lines: defines '$line'" "| \`$line\`" "$rl"
done
check "report lines: a directly merged lane uses the herdr direct row" "gets the format's \`direct\` row" "$rl"
check "report lines: lanes supply the prs block" "gh pr list --head <lane branch> --state all --json number,url,state,isDraft" "$rl"
check "report lines: every pull request of a lane is listed" "all of them are listed" "$rl"
check "report lines: the example is not the report's fence" "never inside a code fence" "$rl"
check "report lines: a pull request is a line with number, state and bare URL" "  - prs:
      ⚪ #812 draft   https://github.com/<owner>/<repo>/pull/812" "$rl"
check "report lines: the added lines carry no emoji" "The lines this plugin adds carry no emoji" "$rl"
check_rc "report lines: no markdown link syntax" 0 "$(grep -c '](http' "$PLUGIN/references/report-lines.md" || true)"
check "report lines: the layout stays the orchestrate plugin's" "fixed format of the \`herdr-simple-orchestrate\` plugin" "$rl"
check "report lines: a lane without a task says so" "\`none\` for a lane without a task" "$rl"
check "report lines: the id is not parsed from a name" "never by splitting its branch or label on hyphens" "$rl"
for skill in task-lane build-lanes build-loop review-lane; do
    sk="$(cat "$PLUGIN/skills/$skill/SKILL.md")"
    check "$skill: reports in the orchestrate plugin's format" "orchestrator report format of the \`herdr-simple-orchestrate\` plugin" "$sk"
    check "$skill: says which lines it adds" "../../references/report-lines.md" "$sk"
done
check_absent "build-lanes: no layout of its own" "keep a roster in every report" "$(cat "$PLUGIN/skills/build-lanes/SKILL.md")"
# The orchestrate plugin's template knows nothing about tasks, gates or boards.
check_rc "the orchestrate report template has no lane lines" 0 "$(grep -cE '^ *(task|gate|board):' "$PLUGINS/../../plugins/herdr-simple-orchestrate/references/report.md" || true)"
check "task-lane: the agent name starts with the kind" "<kind>-lane-<task id, lowercased>" "$tl"
check "task-lane: the no-task agent name starts with the kind" "<kind>-lane-<desc>" "$tl"
check "task-lane: the kind is never cut" "never the kind" "$tl"
check "task-lane: uniqueness goes through the helper" "--taken" "$tl"
check "review-lane: the reviewer's name comes from the helper" "lane_name.py\" --role review --kind" "$(cat "$PLUGIN/skills/review-lane/SKILL.md")"
# shellcheck disable=SC2016  # literal backticks: markdown code spans
old_names="$(grep -rnE '`lane-|`review-<' "$PLUGIN/skills" "$PLUGIN/references" "$PLUGIN/README.md" || true)"
check_rc "no skill or reference still names an agent lane-<id> without its kind" 0 "${#old_names}"
[[ -n "$old_names" ]] && echo "     $old_names"

