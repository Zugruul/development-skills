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
check "worktree: the label has no spaces" "hyphen-separated group of letters and digits with no spaces" "$wt"
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

echo "== lint: orchestrator report =="
rp="$(cat "$PLUGIN/references/report.md" 2>/dev/null)"
check "report: one reference file holds the format" "# Orchestrator report" "$rp"
for part in "Since last report:" "**🔴 NEEDS YOU (1)**" "**🟡 WORKING (1)**" "**🟢 DONE (1)**" "verified:" "claimed:" "asks:" "prs:"; do
    check "report: the template has '$part'" "$part" "$rp"
done
check "report: sections keep their order" "\`NEEDS YOU\`, \`WORKING\`, \`DONE\`" "$rp"
check "report: section dots" "\`🔴 NEEDS YOU (n)\`, \`🟡 WORKING (n)\`, \`🟢 DONE (n)\`" "$rp"
check "report: empty sections are left out" "Leave out a section that has no agents" "$rp"
check "report: nothing changed is said" "Since last report: nothing changed" "$rp"
check "report: the first report has no change line" "Leave the line out of your first report" "$rp"
check "report: markdown, no table" "No table" "$rp"
check "report: never inside a code fence" "Never wrap the report in a code fence" "$rp"
check "report: prs is a block, one line per pull request" "  - prs:
      ⚪ #2795 draft   https://github.com/<owner>/<repo>/pull/2795
      🔵 #2801 open    https://github.com/<owner>/<repo>/pull/2801
      🟣 #2807 merged  https://github.com/<owner>/<repo>/pull/2807
      🔴 #2811 closed  https://github.com/<owner>/<repo>/pull/2811" "$rp"
check "report: claimed starts with the warning mark" "  - claimed: ⚠ 103 + 28 tests pass" "$rp"
check "report: verified has no marker" "\`verified:\` has no marker" "$rp"
check "report: the pull request dots are fixed" "\`⚪ draft\`, \`🔵 open\`, \`🟣 merged\`, \`🔴 closed\`" "$rp"
check "report: green only means DONE" "Green means DONE and nothing else: an open pull request is blue." "$rp"
check_rc "report: no green dot on a pull request line" 0 "$(grep -c '🟢 #' "$PLUGIN/references/report.md" || true)"
check "report: never color alone" "**Never color alone.**" "$rp"
check "report: no other emoji" "These are the only emoji allowed anywhere in the report" "$rp"
check "report: idle, unknown and gone get the black dot" "\`⚫\` is used for nothing else" "$rp"
for line in "⚫ idle:" "⚫ state: unknown" "⚫ gone:"; do
    check "report: the table marks '$line'" "$line" "$rp"
done
# The example block uses only the allowed marks.
# shellcheck disable=SC2016  # literal backticks: a sed address for the fenced block
check_rc "report: no emoji outside the fixed set in the example" 0 "$(sed -n '/^```markdown/,/^```$/p' "$PLUGIN/references/report.md" | python3 -c 'import sys; print(sum(1 for c in sys.stdin.read() if ord(c) > 0x2000 and c not in "🔴🟡🟢🔵⚪🟣⚠⚫"))')"
check "report: one pull request uses the same block" "An agent with one pull request uses the same block" "$rp"
check "report: a direct merge is a row of the prs block" "      ⚪ #2795   draft   https://github.com/<owner>/<repo>/pull/2795
      🟣 direct  merged  main @ 4e843cc" "$rp"
check "report: the direct row comes from git, not from the agent" "**Never write this row from what the agent says or from memory.**" "$rp"
check "report: merged means the remote's main branch" "**\`merged\` means on the remote's main branch**" "$rp"
check "report: local-only work is not purple" "\`⚪ direct  local   main @ <commit>\`" "$rp"
check "report: a squash or cherry-pick is recognised" "(same content)" "$rp"
check "report: earlier states get no row" "**States before that get no row.**" "$rp"
check "report: an unconfirmed landing is a claim" "there is no row; the agent's statement goes under \`claimed:\`" "$rp"
check "report: no double row for a merged pull request" "Do not add a \`direct\` row for the same work." "$rp"
check "report: the color table has the direct marks" "| 🟣 ⚪ | start of a \`direct\` line |" "$rp"
check "status: the report includes direct rows" "a \`direct\` row from \`landed\`" "$(cat "$PLUGIN/skills/status/SKILL.md")"
check "report: no pull requests, no prs line" "An agent with none has no \`prs:\` line" "$rp"
check "report: pull requests in opening order" "in the order they were opened" "$rp"
check "report: the four pull request states" "\`draft\`, \`open\`, \`merged\`, \`closed\`" "$rp"
check "report: the URL is full and bare" "written in full and bare, with no Markdown link syntax" "$rp"
check "report: URLs are aligned" "so the URLs start in the same column" "$rp"
check "report: no invented URL" "never guess an address" "$rp"
check "report: clicking depends on the terminal" "depends on the terminal and on Herdr" "$rp"
check "report: the observed result under default mouse capture" "a click does not open the URL" "$rp"
check "report: names the Herdr setting involved" "ui.mouse_capture = true" "$rp"
check "report: other hosts are unverified" "is unverified, and so is every other host" "$rp"
check "report: no claim that URLs open" "Do not tell the user the URLs are clickable. Under Herdr's defaults they are not." "$rp"
check "report: no workaround and no config change" "Do not change the user's Herdr configuration" "$rp"
check_rc "report: no markdown link syntax anywhere in the reference" 0 "$(grep -c '](http' "$PLUGIN/references/report.md" || true)"
check "report: the question is quoted exactly" "quoted exactly" "$rp"
check "report: only for the orchestrator role" "does not apply to an agent that is not orchestrating" "$rp"
check "report: unknown is never done" "An agent Herdr cannot classify is never shown under DONE" "$rp"
check "report: no agent is dropped" "No agent is silently dropped" "$rp"
# shellcheck disable=SC2016  # literal backticks: these are markdown table cells
for state in '`blocked`' '`working`' '`done`' '`idle`' '`unknown`' 'gone'; do
    check "report: places $state" "| $state" "$rp"
done
# The template itself is fenced plain text, not a table.
# shellcheck disable=SC2016  # literal backticks: a sed address for the fenced block
check_rc "report: the example block has no table row" 0 "$(sed -n '/^```markdown/,/^```$/p' "$PLUGIN/references/report.md" | grep -c '^|' || true)"
for skill in orchestrate listen status worktree; do
    check "report: $skill points to the reference" "../../references/report.md" "$(cat "$PLUGIN/skills/$skill/SKILL.md")"
done
st="$(cat "$PLUGIN/skills/status/SKILL.md")"
check "status: has an orchestrator case" "## 2. Orchestrator case" "$st"
check "status: keeps its plain output when not orchestrating" "## 3. Plain case" "$st"
check "status: the plain case has no report marks" "No sections, no color marks and no \`prs:\` block here" "$st"
check "status: says how it knows which case it is in" "Decide from this conversation only" "$st"
check "status: needs the role" "**The role.**" "$st"
check "status: needs the list of its agents" "**Your agents.**" "$st"
check "status: a name is a hint, not proof" "is a hint that you held the role, never proof" "$st"
check "status: unknown falls back to the plain case and says so" "do not guess. Use the plain case and say so" "$st"
check "status: names the summarised-context case" "after your context was summarised" "$st"
check "status: the orchestrator report comes first" "1. **The orchestrator report** for your agents" "$st"
check "status: then the other live agents" "Other agents (n)" "$st"
check "status: both cases use the overview lists" "3. **The two lists**, after the report, as one fenced block" "$st"
check "status: the plain case uses the same lists" "Print the output of \`overview\` (no \`--mine\`) as one fenced block" "$st"
check "status: the lists are pasted in a code block" "unchanged inside one fenced code block" "$st"
check "status: the report itself stays unfenced" "the orchestrator report keeps its own rule and is never fenced" "$st"
check "status: agents carry the workspace label" "workspace id, workspace label, kind, state, then the agent's name when it has one" "$st"
check "status: unnamed agents are targeted through roster" "read it from \`roster\`" "$st"
check "status: worktree heading carries the counts" "Worktrees (3 open of 85)" "$st"
check "status: lists carry no paths" "No paths, no pane or tab columns" "$st"
check_absent "status: no long per-agent lines any more" "name, kind, state, directory" "$st"
check "status: since-last-report works on demand" "works the same for an on-demand call" "$st"
check "status: a lost earlier report is said, not reconstructed" "Since last report: unknown (the earlier report is no longer in my context)" "$st"
check "status: a status call counts as the last report" "it becomes the \"last report\" the next one is compared with" "$st"
check "status: still read-only" "This skill only reads." "$st"
for phrase in "'/herdr:status'" "'report on status'" "'status report'" "'how are the agents doing'"; do
    check "status: the description triggers on $phrase" "$phrase" "$(sed -n 's/^description: //p' "$PLUGIN/skills/status/SKILL.md")"
done
check "report: the reference covers an on-demand comparison" "or on demand through the \`status\` skill" "$rp"
check "orchestrate: points to status for on-demand reports" "The \`status\` skill is the on-demand form of this report" "$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
orch_txt="$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
check "orchestrate: the user's questions about an agent's work are relayed" "**The user's questions about an agent's work go to that agent.**" "$orch_txt"
check "orchestrate: relaying covers questions, errors and bug reports" "asks a question, shows an error, reports a bug" "$orch_txt"
check "orchestrate: no investigating the agent's checkout" "Do not open the agent's checkout to work out the answer yourself" "$orch_txt"
check "orchestrate: read-only work is delegated work too" "This holds for read-only work as much as for edits." "$orch_txt"
check "orchestrate: a mid-turn agent is waited for" "wait until it settles and send then" "$orch_txt"
check "orchestrate: an unowned topic is asked about, not taken" "ask the user who should take it" "$orch_txt"
check "orchestrate: verifying is not investigating" "It is not investigating: diagnosing an error, explaining a design choice or proposing a change" "$orch_txt"
check "orchestrate: the role covers more than editing files" "Delegated work is more than editing files" "$orch_txt"
check "prompt: has the user-to-agent direction" "## Relay the user's question or request" "$(cat "$PLUGIN/skills/prompt/SKILL.md")"
check "orchestrate: states the role in the conversation" "Say in that reply that you are now the orchestrator" "$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
check "report: listen keeps its own output when not orchestrating" "Otherwise summarise per agent" "$(cat "$PLUGIN/skills/listen/SKILL.md")"
check_absent "report: orchestrate no longer describes its own layout" "Keep a roster" "$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"

# Standalone: nothing in this plugin may know the specialized plugins.
leak="$(grep -rnoiE 'spec-workflow|build-next|implement-task|peer-review|remote-compute|\.neural-network|board\.sh' "$PLUGIN" --include='*.md' --include='*.py' --include='*.json' --exclude-dir=tests || true)"
check_rc "no specialized-plugin knowledge leaks into the herdr plugin" 0 "${#leak}"
[[ -n "$leak" ]] && echo "     $leak"

bad="$(grep -rnE '(^|[^a-zA-Z0-9_])bash +"[^"]*\.py"' "$PLUGIN/skills/" 2>/dev/null || true)"
check_absent "no skill invokes a .py via bash" ".py" "$bad"
v1="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN/.claude-plugin/plugin.json")"
v2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$PLUGIN/.codex-plugin/plugin.json")"
check "claude and codex manifests carry the same version" "$v1" "$v2"
