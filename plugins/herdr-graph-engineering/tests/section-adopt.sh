#!/usr/bin/env bash
# section-adopt.sh -- sourced by run-tests.sh; do not run standalone.
# adopt.sh (an agent started outside the graph becomes a one-node lane), start.sh (the session file
# before anything else), the resume block after a compaction without one, and what the skills say.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

O_TMP="$(mktemp -d)"
O_REPO="$O_TMP/repo"
git init -q -b main "$O_REPO" && git -C "$O_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$O_REPO" worktree add -q -b feat/hand "$O_TMP/wt-hand" main
O_STATE_OLD="$XDG_STATE_HOME"; export XDG_STATE_HOME="$O_TMP/state" XDG_CONFIG_HOME="$O_TMP/config"
os() { local s="$1"; shift; (cd "$O_TMP" && PATH="$FIX/stub-herdr:$FIX/stub-gh:$PATH" HERDR_STUB_DIR="$O_TMP" GH_STUB_DIR="$O_TMP" HERDR_ENV=1 HERDR_PANE_ID="${O_PANE:-w1:p1}" NO_COLOR=1 HERDR_GRAPH_NO_SIGNAL=1 bash "$PLUGIN/scripts/$s.sh" "$@"); }
ost() { printf '%s' "$1" >"$O_TMP/state.json"; : >"$O_TMP/calls.log"; }
ol() { yq -r "$2" "$O_REPO/.git/herdr-graph/$1.yaml"; }
oagent() { jq -cn --arg n "$1" --arg s "$2" --arg d "$3" --arg p "$4" '{name: $n, pane_id: $p, tab_id: ($p | split(":")[0] + ":t3"), workspace_id: ($p | split(":")[0]), agent: "claude", agent_status: $s, state_change_seq: 1, cwd: $d, foreground_cwd: $d}'; }
oagents() { jq -cn --argjson o "$(oagent graph idle "$O_TMP" w1:p1)" --argjson h "$(oagent claude-hand "${1:-working}" "$O_TMP/wt-hand" w2:p1)" --argjson r "$(oagent claude-two idle "$O_TMP/wt-hand" w3:p1)" '{agents: {o: $o, h: $h, r: $r}}'; }

echo "== start: the session file is the first thing =="
ost "$(oagents)"
out="$(os start --scratch "$O_TMP/scratch")"
check "it records the session" "STARTED graph" "$out"
check "its pane" "w1:p1" "$(os session show --json | jq -r .pane)"
check "its name" "graph" "$(os session show --json | jq -r .orchestrator)"
check "its scratch folder" "$O_TMP/scratch" "$(os session show --json | jq -r .scratch)"
check "and says AFK and auto-merge are off" "AFK off" "$out"
out="$(O_PANE=w9:p9 os start --scratch "$O_TMP/s" 2>&1)"; rc=$?
check_rc "a pane without an agent cannot start" 6 "$rc"

echo "== resume: after a compaction without a session file =="
rm -rf "$XDG_STATE_HOME"
out="$(printf '{}' | os resume --hook session-start)"
check "a pane named graph still gets the block" "RESUME" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")"
check "which says why it has no session" "no session file for this pane" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")"
check "another pane gets nothing" "[]" "[$(printf '{}' | O_PANE=w2:p1 os resume --hook session-start)]"
check_absent "the agent limit of 3 is gone" "of 3 agents" "$(os resume)"
check_absent "from the skill too" "fewer than 3" "$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"

echo "== adopt: each refusal =="
os start --scratch "$O_TMP/scratch" >/dev/null
ad() { os adopt --repo "$O_REPO" "$@" 2>&1; }
out="$(ad --agent nobody --idea x --access read)"; rc=$?
check_rc "a gone agent is not adopted" 6 "$rc"
out="$(ad --agent claude-hand --idea x --access sideways)"; rc=$?
check_rc "access is read or write" 2 "$rc"
os lane new --repo "$O_REPO" --lane busy --pattern solo --idea x --gate true --branch feat/hand --workspace w3 --owner graph >/dev/null
os lane node --repo "$O_REPO" --lane busy --node impl --status running --agent claude-two >/dev/null
out="$(ad --agent claude-hand --idea x --access write)"; rc=$?
check_rc "never a second writer in a checkout" 6 "$rc"
check "and says who writes there" "claude-two" "$out"
out="$(ad --agent claude-two --idea x --access read)"; rc=$?
check_rc "an agent a lane already records is not adopted twice" 6 "$rc"
check "naming the lane" "busy" "$out"
os lane close --repo "$O_REPO" --lane busy >/dev/null

echo "== adopt: a one-node lane =="
: >"$O_TMP/calls.log"
out="$(ad --agent claude-hand --idea "finish the docs" --access write --lane hand)"
check "it makes the lane" "ADOPTED hand claude-hand" "$out"
check "marked adopted" "true" "$(ol hand .adopted)"
check "owned by this orchestrator" "graph" "$(ol hand .owner)"
check "its node runs with the agent" "running claude-hand" "$(ol hand '"\(.nodes.work.status) \(.nodes.work.agent)"')"
check "no tab is recorded, so it is never closed" "null" "$(ol hand .nodes.work.tab)"
check "the checkout's branch" "feat/hand" "$(ol hand .branch)"
check "the protocol is sent once, as it is not blocked" "PROTOCOL SENT" "$out"
check "to the agent" "agent prompt claude-hand" "$(cat "$O_TMP/calls.log")"
proto="$(jq -r '.agents.h.last_prompt' "$O_TMP/state.json")"
check "it asks for the result line" "NODE work RESULT:" "$proto"
check "and says it is not the user" "not the user" "$proto"
check "echoed back, it is no result" "none" "$(bash -c '. "$1/scripts/src/result.sh"; screen_claim work "$2" | jq -r .kind' _ "$PLUGIN" "$proto")"
check "close-done closes nothing of it" "[]" "[$(os close-done --repo "$O_REPO" --lane hand | grep '^CLOSE' || true)]"
ost "$(oagents blocked)"
os lane close --repo "$O_REPO" --lane hand >/dev/null
out="$(ad --agent claude-hand --idea x --access read --lane look)"
check "a blocked agent is sent nothing" "PROTOCOL NOT SENT" "$out"
check_absent "nothing typed into its dialog" "agent prompt" "$(cat "$O_TMP/calls.log")"
check "a read adoption keeps the baseline" "$(git -C "$O_TMP/wt-hand" rev-parse HEAD)" "$(ol look .baseline.head)"
ost "$(oagents idle)"
check "it can be sent later" "PROTOCOL SENT" "$(os adopt --protocol --repo "$O_REPO" --lane look)"
check "but only once" "ALREADY SENT" "$(os adopt --protocol --repo "$O_REPO" --lane look)"

echo "== adopt: cleanup closes the record only =="
os lane node --repo "$O_REPO" --lane look --node work --status "done" --result pass >/dev/null
os lane set --repo "$O_REPO" --lane look --key status --value "done" >/dev/null
os cleanup check --repo "$O_REPO" --lane look >/dev/null
check "the question says the checkout stays" "checkout is left as it is" "$(ol look .question)"
os lane answer --repo "$O_REPO" --lane look --text yes >/dev/null
os lane set --repo "$O_REPO" --lane look --key cleanup --value confirmed >/dev/null
: >"$O_TMP/calls.log"
out="$(os cleanup run --repo "$O_REPO" --lane look)"
check "the record is closed" "CLEANED look" "$out"
check_absent "no worktree is removed" "worktree remove" "$(cat "$O_TMP/calls.log")"
check "the checkout is still there" "yes" "$([ -d "$O_TMP/wt-hand" ] && echo yes)"

echo "== skills: the proactive rules =="
orch="$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
afk="$(cat "$PLUGIN/skills/afk/SKILL.md" 2>/dev/null)"
am="$(cat "$PLUGIN/skills/auto-merge/SKILL.md" 2>/dev/null)"
check "orchestrate: starts with start.sh" 'bash "../../scripts/start.sh"' "$orch"
check "orchestrate: has the section events point to" "## When an event arrives" "$orch"
check "orchestrate: asks at once, in a dialog, after recording it" "lane.sh asked" "$orch"
check "orchestrate: never asks about AFK" "Never ask whether the user is AFK" "$orch"
check "orchestrate: cleanup one lane at a time with previews" "one lane at a time" "$orch"
check "orchestrate: previews from cleanup facts" "cleanup.sh\" facts" "$orch"
check "orchestrate: merges only through merge.sh" 'merge.sh" run' "$orch"
check "orchestrate: never approves or force-pushes" "**Never** approve, force-push" "$orch"
check "orchestrate: adopts with adopt.sh" 'adopt.sh' "$orch"
check "orchestrate: rejects a claim that does not hold" "lane.sh reject" "$orch"
check "afk: only the command sets it" "Only this command turns AFK on or off" "$afk"
check "afk: never asks to turn it on" "Never ask whether the user is AFK" "$afk"
check "afk: records before acting" "decide.sh" "$afk"
check "afk: says tier 3 always waits" "Tier 3" "$afk"
check "afk: shows the list and asks still away" "still away?" "$afk"
check "afk: worktree removal only when ticked" "cleanup.sh\" run --afk" "$afk"
check "afk: no dialog while away" "do not open a question dialog" "$afk"
check "auto-merge: off by default" "off by default" "$am"
check "auto-merge: asks when no argument" "AskUserQuestion" "$am"
check "auto-merge: scopes" "--repo" "$am"
check "auto-merge: only through merge.sh" "merge.sh" "$am"
check "auto-merge: a draft is marked ready" "marks a draft ready" "$am"
for r in "$PLUGIN"/roles/*.md; do
    check "role $(basename "$r" .md): a step is not the result" "NODE {node} STEP:" "$(cat "$r")"
    check "role $(basename "$r" .md): the result file with the run id" '{output_path}.result.json' "$(cat "$r")"
done
check "brief format: fills the run id" "{run}" "$(cat "$PLUGIN/references/brief-format.md")"

git -C "$O_REPO" worktree prune 2>/dev/null
rm -rf "$O_TMP"
export XDG_STATE_HOME="$O_STATE_OLD"; unset XDG_CONFIG_HOME
unset -f os ost ol oagent oagents ad
