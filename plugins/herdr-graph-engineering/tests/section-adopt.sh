#!/usr/bin/env bash
# section-adopt.sh -- sourced by run-tests.sh; do not run standalone.
# Adopting agents that already run: the one-node adopt pattern and the orchestrate skill's recipe.
# The recipe changes no script, so these tests run it through the shipped scripts: what it
# records shows in the graph, nothing the graph did not create is closed or removed, the sent
# message is never read as a result, and a finished agent goes straight to CLOSED.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

A_TMP="$(mktemp -d)"
A_REPO="$A_TMP/repo"
git init -q -b main "$A_REPO" && git -C "$A_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
export XDG_CONFIG_HOME="$A_TMP/config"
ag() { local s="$1"; shift; (cd "$A_TMP" && PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$A_TMP" HERDR_ENV=1 NO_COLOR=1 bash "$PLUGIN/scripts/$s.sh" "$@"); }
A_DIR="$(git -C "$A_REPO" rev-parse --path-format=absolute --git-common-dir)/herdr-graph"
screen() { # status seq text
    jq -cn --arg s "$1" --argjson q "$2" --arg t "$3" \
        '{agents: {a: {name: "old-1", pane_id: "w5:p1", tab_id: "w5:t2", workspace_id: "w5", agent_status: $s, state_change_seq: $q, screen: $t}},
          tabs: {"w5:t2": {tab_id: "w5:t2", workspace_id: "w5", number: 2, agent_status: $s}}}' >"$A_TMP/state.json"
}
sect() { ag status --json --repo "$A_REPO" | jq -r --arg l "$1" '.[] | select(.lane == $l) | .section'; }
: >"$A_TMP/calls.log"

echo "== adopt: the pattern =="
pat="$PLUGIN/patterns/adopt.yaml"
pjson="$(yq -o=json '.' "$pat" 2>/dev/null)"
check "adopt: shipped and valid" "PATTERN OK" "$(ag check-pattern "$pat" 2>&1)"
check "adopt: one agent node, no gate and no pull request node" '["work"]' "$(jq -c '.nodes | keys' <<<"$pjson")"
check "adopt: done is only the user's yes to close" '["human"]' "$(jq -c '[.done[] | keys[]]' <<<"$pjson")"
check "adopt: the pattern says it is only for an explicit ask" "only when the user explicitly asks" "$(jq -r '.when' <<<"$pjson")"

echo "== adopt: the recipe in the orchestrate skill =="
recipe="$(awk '/^## / {f = ($0 == "## Adopting a running agent")} f' "$PLUGIN/skills/orchestrate/SKILL.md")"
check "recipe: only on the user's request" "Only when the user asks to take over" "$recipe"
check "recipe: never on the orchestrator's own initiative" "Never on your own" "$recipe"
check "recipe: for all of them, the list and a yes come first" 'for "all", show the list and get a yes' "$recipe"
check "recipe: no branch, workspace or tab" 'Pass no `--branch`, `--workspace` or `--tab`' "$recipe"
check "recipe: steps are PROGRESS lines" 'lane.sh note --repo R --lane L --node work' "$recipe"
check "recipe: a finished agent is sent nothing" "send nothing" "$recipe"
check "recipe: closed, never done" 'never `--key status --value done`' "$recipe"
check "recipe: never cleanup" 'never `cleanup.sh`' "$recipe"
check "recipe: lane names differ across repositories" "across repositories" "$recipe"
check_absent "recipe: shows no filled-in RESULT line" "NODE work RESULT: pass" "$recipe"
check_absent "recipe: shows no filled-in failing RESULT line" "NODE work RESULT: fail" "$recipe"
check_absent "recipe: shows no filled-in question RESULT line" "NODE work RESULT: question" "$recipe"
# the message as the skill ships it: read from SKILL.md, so a concrete example added to it fails here
MSG="$(grep -F 'The graph orchestrator now tracks you' <<<"$recipe")"
check "recipe: ships the message on one line, with placeholders" 'NODE work RESULT: <pass|fail|question> <commit, pull request or file>' "$MSG"
check "recipe: the message names the PROGRESS line" 'PROGRESS work:' "$MSG"
check "router: routes an explicit adoption to adopt" '| adopt,' "$(cat "$PLUGIN/references/router.md")"
check "router: never otherwise" "never otherwise" "$(grep -F '| adopt,' "$PLUGIN/references/router.md")"
check "readme: lists adopt" '| `adopt` |' "$(cat "$PLUGIN/README.md")"

echo "== adopt: a running agent is a lane in the graph =="
ag lane new --repo "$A_REPO" --lane old-1 --pattern adopt --idea "its task, see https://github.com/o/r/pull/6" --owner graph >/dev/null
ag lane set --repo "$A_REPO" --lane old-1 --key pr --value https://github.com/o/r/pull/6 >/dev/null
ag lane node --repo "$A_REPO" --lane old-1 --node work --status running --agent old-1 >/dev/null
screen idle 3 "$MSG
PROGRESS work: step 1 ended, step 2 next"
out="$(ag drift --repo "$A_REPO")"
check_absent "the quoted rule and PROGRESS are no result" "finished" "$out"
check "idle without a result shows as stopped" "stopped: old-1" "$out"
ag lane note --repo "$A_REPO" --lane old-1 --node work --text "PROGRESS work: step 1 ended, step 2 next" >/dev/null
check "a recorded step shows with the lane" "PROGRESS work: step 1 ended" "$(ag status --text --repo "$A_REPO")"
screen working 4 "step 2"
check "a working adopted agent is working" "working" "$(sect old-1)"
# an older merged pull request must not count for a lane that records no branch
jq -cn '{fetched: 1, lanes: {"old-1": [
    {number: 1, url: "https://github.com/o/r/pull/1", state: "MERGED", isDraft: false, reviewDecision: "", headRefName: "main"},
    {number: 6, url: "https://github.com/o/r/pull/6", state: "OPEN", isDraft: false, reviewDecision: "", headRefName: "main"}]}}' >"$A_DIR/prs.json"
check_absent "another merged pull request does not count without a branch" "merged" "$(ag status --json --repo "$A_REPO" | jq -r '.[].attention[]')"
screen idle 5 "NODE work RESULT: pass 1a2b3c4"
check "its real result is read" "finished pass 1a2b3c4" "$(ag drift --repo "$A_REPO")"
ag lane node --repo "$A_REPO" --lane old-1 --node work --status "done" --result pass --ref 1a2b3c4 >/dev/null
check "no tab is ever closed" "KEEP work (no tab recorded)" "$(ag close-done --repo "$A_REPO" --lane old-1)"
check_absent "cleanup leaves the open lane alone" "old-1" "$(ag cleanup check --repo "$A_REPO")"
ag lane close --repo "$A_REPO" --lane old-1 >/dev/null
check "a closed adopted lane is under CLOSED" "closed" "$(sect old-1)"
check "and still keeps its agent's tab" "KEEP work (no tab recorded)" "$(ag close-done --repo "$A_REPO" --lane old-1)"

echo "== adopt: an already finished agent goes straight to CLOSED =="
ag lane new --repo "$A_REPO" --lane fin-1 --pattern adopt --idea "already finished" --owner graph >/dev/null
ag lane node --repo "$A_REPO" --lane fin-1 --node work --status "done" --result pass --ref abc1234 --agent old-1 >/dev/null
ag lane close --repo "$A_REPO" --lane fin-1 >/dev/null
check "new, node, close: under CLOSED" "closed" "$(sect fin-1)"
check "it shows without a Herdr workspace for its repository" "fin-1" "$(ag status --json | jq -r '.[].lane')"
calls="$(cat "$A_TMP/calls.log")"
check_absent "no tab was closed" "tab close" "$calls"
check_absent "no worktree was removed" "worktree remove" "$calls"
check_absent "the scripts sent the agent nothing" "agent prompt" "$calls"

rm -rf "$A_TMP"
unset XDG_CONFIG_HOME
