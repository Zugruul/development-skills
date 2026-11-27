#!/usr/bin/env bash
# section-adopt-pattern.sh -- sourced by run-tests.sh; do not run standalone.
# The one adoption section of the orchestrate skill, and the adopt pattern for an agent that has
# already finished (adopt.sh, tested in section-adopt.sh, is for one still at work). The finished
# path runs through the shipped scripts: nothing is sent to the agent, nothing the graph did not
# create is closed or removed, and the lane goes straight to CLOSED.
# shellcheck disable=SC2016  # the backticks are text in the skill and README
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

A_TMP="$(mktemp -d)"
A_REPO="$A_TMP/repo"
git init -q -b main "$A_REPO" && git -C "$A_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
export XDG_CONFIG_HOME="$A_TMP/config"
ag() { local s="$1"; shift; (cd "$A_TMP" && PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$A_TMP" HERDR_ENV=1 NO_COLOR=1 HERDR_GRAPH_NO_SIGNAL=1 bash "$PLUGIN/scripts/$s.sh" "$@"); }
sect() { ag status --json --repo "$A_REPO" | jq -r --arg l "$1" '.[] | select(.lane == $l) | .section'; }
jq -cn '{agents: {a: {name: "old-1", pane_id: "w5:p1", tab_id: "w5:t2", workspace_id: "w5", agent_status: "idle", state_change_seq: 3, screen: "all done"}},
    tabs: {"w5:t2": {tab_id: "w5:t2", workspace_id: "w5", number: 2, agent_status: "idle"}}}' >"$A_TMP/state.json"
: >"$A_TMP/calls.log"

echo "== adopt pattern: only for an agent that already finished =="
pat="$PLUGIN/patterns/adopt.yaml"
pjson="$(yq -o=json '.' "$pat" 2>/dev/null)"
check "adopt: shipped and valid" "PATTERN OK" "$(ag check-pattern "$pat" 2>&1)"
check "adopt: one agent node, no gate and no pull request node" '["work"]' "$(jq -c '.nodes | keys' <<<"$pjson")"
check "adopt: done is only the user's yes to close" '["human"]' "$(jq -c '[.done[] | keys[]]' <<<"$pjson")"
check "adopt: the pattern says it is only for an explicit ask" "Only when the user explicitly asks" "$(jq -r '.when' <<<"$pjson")"
check "adopt: the pattern says it is only for a finished agent" "has already finished all its work" "$(jq -r '.when' <<<"$pjson")"
check "adopt: the pattern sends a running one to adopt.sh" "adopt.sh" "$(jq -r '.when' <<<"$pjson")"

echo "== adopt pattern: one adoption section in the orchestrate skill =="
orch="$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
check_rc "skill: exactly one adoption section" 1 "$(grep -c '^## Adopting' <<<"$orch")"
recipe="$(awk '/^## / {f = ($0 == "## Adopting an agent")} f' <<<"$orch")"
check "skill: only on an explicit request" "Only when the user explicitly asks" "$recipe"
check "skill: never on the orchestrator's own initiative, also under AFK" "Never adopt an agent on your own, also under AFK" "$recipe"
check "skill: only the named agents" "Adopt only the agents they name" "$recipe"
check "skill: for all of them, the list and a yes come first" 'for "all", show the list and get a yes' "$recipe"
check "skill: a running agent goes through adopt.sh" 'bash "../../scripts/adopt.sh" --agent' "$recipe"
check "skill: a finished agent does not" 'not `adopt.sh`' "$recipe"
check "skill: a finished agent is sent nothing" "send nothing" "$recipe"
check "skill: the finished path uses the adopt pattern" "--pattern adopt " "$recipe"
check "skill: the finished path records no branch, workspace or tab" 'Pass no `--branch`, `--workspace` or `--tab`' "$recipe"
check "skill: the finished lane is closed, never done" 'never `--key status --value done`' "$recipe"
check "skill: lane names differ across repositories" "across repositories" "$recipe"
check_absent "skill: no second protocol for steps" "PROGRESS" "$recipe"
check_absent "skill: no message sent by hand" "The graph orchestrator now tracks you" "$recipe"
check_absent "skill: shows no result line to copy" "NODE work RESULT:" "$recipe"
row="$(grep -F 'take over or adopt' "$PLUGIN/references/router.md")"
check "router: points at the skill's section" '"Adopting an agent"' "$row"
check "router: a running agent: adopt.sh" '`adopt.sh`' "$row"
check "router: a finished agent: the adopt pattern" 'the `adopt` pattern' "$row"
check "router: never otherwise" "never otherwise" "$row"
rme="$(cat "$PLUGIN/README.md")"
check "readme: the adopt pattern is for a finished agent" "already finished" "$(grep -F '| `adopt` |' <<<"$rme")"
rsec="$(awk '/^## / {f = ($0 == "## Adopting an agent")} f' <<<"$rme")"
check "readme: only on an explicit request" "only when you ask" "$rsec"
check "readme: a finished agent is sent nothing" "sends it nothing" "$rsec"
check_absent "readme: no running agent on the adopt pattern" "one \`work\` node on the running agent" "$rme"

echo "== adopt pattern: an already finished agent goes straight to CLOSED =="
ag lane new --repo "$A_REPO" --lane fin-1 --pattern adopt --idea "already finished" --owner graph >/dev/null
ag lane set --repo "$A_REPO" --lane fin-1 --key pr --value https://github.com/o/r/pull/6 >/dev/null
ag lane node --repo "$A_REPO" --lane fin-1 --node work --status "done" --result pass --ref abc1234 --agent old-1 >/dev/null
ag lane close --repo "$A_REPO" --lane fin-1 >/dev/null
check "new, node, close: under CLOSED" "closed" "$(sect fin-1)"
check "it shows without a Herdr workspace for its repository" "fin-1" "$(ag status --json | jq -r '.[].lane')"
check "its agent's tab is kept" "KEEP work (no tab recorded)" "$(ag close-done --repo "$A_REPO" --lane fin-1)"
calls="$(cat "$A_TMP/calls.log")"
check_absent "no tab was closed" "tab close" "$calls"
check_absent "no worktree was removed" "worktree remove" "$calls"
check_absent "the agent was sent nothing" "agent prompt" "$calls"

rm -rf "$A_TMP"
unset XDG_CONFIG_HOME
unset -f ag sect
