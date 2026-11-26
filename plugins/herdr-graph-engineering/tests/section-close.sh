#!/usr/bin/env bash
# section-close.sh -- sourced by run-tests.sh; do not run standalone.
# close-done.sh: when a finished node's tab is closed, and what is never closed.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

C_TMP="$(mktemp -d)"
C_SC="$PLUGIN/scripts"
C_REPO="$C_TMP/repo"
git init -q -b main "$C_REPO" && git -C "$C_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
export XDG_CONFIG_HOME="$C_TMP/config"
c() { local s="$1"; shift; PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$C_TMP" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 bash "$C_SC/$s.sh" "$@"; }
# Tabs in the stub: cst 'w2:t2 w2:t3 ...' makes each a second-or-later idle tab of w2.
cst() { # tab ids, then optional extra jq applied to the state
    local tabs="$1" extra="${2:-.}"
    jq -cn --arg t "$tabs" "{tabs: ([\$t | split(\" \")[] | select(. != \"\") | {(.): {tab_id: ., workspace_id: (split(\":\")[0]), number: 2, agent_status: \"idle\", label: \"x\"}}] | add // {})} | $extra" >"$C_TMP/state.json"
    : >"$C_TMP/calls.log"
}
clf() { yq -r "$1" "$(git -C "$C_REPO" rev-parse --path-format=absolute --git-common-dir)/herdr-graph/$2.yaml"; }
c_herdr() { PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$C_TMP" herdr "$@"; }
cnode() { c lane node --repo "$C_REPO" "$@" >/dev/null; }
cd_() { c close-done --repo "$C_REPO" "$@" 2>&1; }

echo "== close: the lane file records each node's tab =="
c lane new --repo "$C_REPO" --lane solo-1 --pattern solo --idea x --gate "npm test" --workspace w2 >/dev/null
cnode --lane solo-1 --node impl --status running --agent claude-solo-1-impl --tab w2:t2
check "lane.sh node --tab records the tab" "w2:t2" "$(clf '.nodes.impl.tab' solo-1)"
out="$(c lane node --repo "$C_REPO" --lane solo-1 --node impl --status running --tab 2>&1)"; rc=$?
check_rc "--tab needs a value" 2 "$rc"

echo "== close: an implementer stays while a gate can still retry it =="
cst "w2:t2"
cnode --lane solo-1 --node impl --status "done" --result pass --ref abc
out="$(cd_ --lane solo-1)"
check "the implementer is kept while its gate has not passed" "KEEP impl" "$out"
check "the reason names the retry edge" "tests can still retry impl" "$out"
check_absent "nothing is closed" "tab close" "$(cat "$C_TMP/calls.log")"
check "a node without a tab is never closed" "KEEP tests (no tab recorded)" "$out"

echo "== close: a failed gate keeps its output =="
cst "w2:t2 w2:t3"
cnode --lane solo-1 --node tests --status failed --result fail --exit 1 --tab w2:t3
out="$(cd_ --lane solo-1)"
check "a failed gate tab is kept" "KEEP tests" "$out"
check "the reason says why" "gate failed" "$out"
check_absent "nothing is closed after a failure" "tab close" "$(cat "$C_TMP/calls.log")"

echo "== close: gate passed, both tabs close =="
c lane retry --repo "$C_REPO" --lane solo-1 --node tests >/dev/null
check "a retry keeps the recorded tab" "w2:t2 w2:t3" "$(clf '[.nodes.impl.tab, .nodes.tests.tab] | join(" ")' solo-1)"
cnode --lane solo-1 --node impl --status "done" --result pass
cnode --lane solo-1 --node tests --status running --tab w2:t3
out="$(cd_ --lane solo-1)"
check "a running gate is kept" "KEEP tests (running)" "$out"
cnode --lane solo-1 --node tests --status "done" --result pass --exit 0
out="$(cd_ --lane solo-1 --dry-run)"
check "dry run: the gate would close" "CLOSE tests w2:t3" "$out"
check "dry run: the implementer would close" "CLOSE impl w2:t2" "$out"
check_absent "dry run closes nothing" "tab close" "$(cat "$C_TMP/calls.log")"
check_absent "dry run records nothing" "true" "$(clf '.nodes.impl.tab_closed' solo-1)"
out="$(cd_ --lane solo-1)"
check "the passed gate's tab is closed" "tab close w2:t3" "$(cat "$C_TMP/calls.log")"
check "the implementer's tab is closed" "tab close w2:t2" "$(cat "$C_TMP/calls.log")"
check "the close is recorded through lane.sh" "true true" "$(clf '[.nodes.impl.tab_closed, .nodes.tests.tab_closed] | join(" ")' solo-1)"
check "the close is in the history" "impl tab w2:t2 closed" "$(clf '.history | join("\n")' solo-1)"
: >"$C_TMP/calls.log"
out="$(cd_ --lane solo-1)"
check "a closed tab is not closed twice" "CLOSED impl" "$out"
check_absent "no second close call" "tab close" "$(cat "$C_TMP/calls.log")"
cnode --lane solo-1 --node tests --status running --tab w2:t4
check "a new tab clears the closed mark" "w2:t4 null" "$(clf '[.nodes.tests.tab, (.nodes.tests.tab_closed // "null")] | join(" ")' solo-1)"

echo "== close: pair, the implementer waits for the reviewer =="
c lane new --repo "$C_REPO" --lane pair-1 --pattern pair --idea x --gate "npm test" --workspace w2 >/dev/null
cst "w2:t2 w2:t3 w2:t4"
cnode --lane pair-1 --node impl --status "done" --result pass --tab w2:t2
cnode --lane pair-1 --node tests --status "done" --result pass --exit 0 --tab w2:t3
cnode --lane pair-1 --node review --status running --agent codex-pair-1-review --tab w2:t4
out="$(cd_ --lane pair-1 --dry-run)"
check "the implementer stays while the reviewer can ask for changes" "KEEP impl" "$out"
check "the reason names the reviewer" "review can still retry impl" "$out"
check "the gate that passed closes" "CLOSE tests" "$out"
check "the running reviewer stays" "KEEP review (running)" "$out"
cnode --lane pair-1 --node review --status "done" --result changes --ref /tmp/f.md
out="$(cd_ --lane pair-1 --dry-run)"
check "a reviewer asking for changes stays until the retry" "KEEP review" "$out"
check "its implementer stays" "KEEP impl" "$out"
cnode --lane pair-1 --node review --status "done" --result pass --ref /tmp/f.md
out="$(cd_ --lane pair-1 --dry-run)"
check "after the reviewer passes the implementer closes" "CLOSE impl w2:t2" "$out"
check "the reviewer that passed closes" "CLOSE review w2:t4" "$out"

echo "== close: review, the reviewer waits for the approval =="
c lane new --repo "$C_REPO" --lane rev-1 --pattern review --idea x --input pr=https://github.com/o/r/pull/7 --workspace w2 >/dev/null
cst "w2:t2 w2:t3"
cnode --lane rev-1 --node review --status "done" --result pass --ref /tmp/d.md --tab w2:t2
out="$(cd_ --lane rev-1 --dry-run)"
check "the reviewer stays until approve is decided" "KEEP review" "$out"
check "the reason names the approval" "approve is not decided" "$out"
cnode --lane rev-1 --node approve --status "done" --result pass
cnode --lane rev-1 --node post --status running --agent claude-rev-1-post --tab w2:t3
out="$(cd_ --lane rev-1)"
check "once approve is decided the reviewer closes" "CLOSE review w2:t2" "$out"
check "the running poster stays" "KEEP post (running)" "$out"
cnode --lane rev-1 --node post --status "done" --result pass
cst "w2:t3" '.tabs["w2:t3"].agent_status = "working"'
out="$(cd_ --lane rev-1)"
check "an agent Herdr shows working is never closed" "KEEP post (agent is working)" "$out"
cst "w2:t3" '.tabs["w2:t3"].agent_status = "blocked"'
check "an agent Herdr shows blocked is never closed" "KEEP post (agent is blocked)" "$(cd_ --lane rev-1)"
cst "w2:t3"
c lane set --repo "$C_REPO" --lane rev-1 --key status --value "done" >/dev/null
out="$(cd_ --lane rev-1)"
check "at lane done the poster closes" "CLOSE post w2:t3" "$out"
check "the poster's tab is closed" "tab close w2:t3" "$(cat "$C_TMP/calls.log")"

echo "== close: lane done closes every agent tab it started =="
c lane new --repo "$C_REPO" --lane solo-2 --pattern solo --idea x --gate t --workspace w2 >/dev/null
cst "w2:t2"
cnode --lane solo-2 --node impl --status "done" --result pass --tab w2:t2
check "before lane done the implementer is kept" "KEEP impl" "$(cd_ --lane solo-2 --dry-run)"
c lane set --repo "$C_REPO" --lane solo-2 --key status --value "done" >/dev/null
check "at lane done it closes" "CLOSE impl w2:t2 (lane is done)" "$(cd_ --lane solo-2 --dry-run)"
c lane close --repo "$C_REPO" --lane solo-2 >/dev/null
out="$(cd_ --lane solo-2)"
check "a closed lane's tabs close too" "CLOSE impl w2:t2 (lane is closed)" "$out"
check "the closed lane's tab is closed" "tab close w2:t2" "$(cat "$C_TMP/calls.log")"

echo "== close: the skill's steps record the tab id, not the pane id =="
c lane new --repo "$C_REPO" --lane ids-1 --pattern investigate --idea x --workspace w5 >/dev/null
cst ""
created="$(c_herdr tab create --workspace w5 --cwd /w --label investigate --no-focus)"
pane="$(jq -r '.result.root_pane.pane_id' <<<"$created")"
tab="$(c_herdr pane get "$pane" | jq -r '.result.pane.tab_id')"
check_absent "in the fixture a tab id is not its pane id" "$pane" "$tab"
cnode --lane ids-1 --node investigate --status running --agent claude-ids-1-investigate --tab "$tab"
cnode --lane ids-1 --node investigate --status "done" --result pass
out="$(cd_ --lane ids-1)"
check "the tab read through pane get is closed" "CLOSE investigate $tab" "$out"
check_absent "it is not mistaken for a gone tab" "GONE" "$out"
check "herdr closes that tab" "tab close $tab" "$(cat "$C_TMP/calls.log")"
check "the stub no longer has it" "$tab" "$(jq -r '.tabs_closed | join(" ")' "$C_TMP/state.json")"
check "orchestrate: reads the tab id through pane get" "herdr pane get <its root pane id>" "$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
check "orchestrate: names the tab id field" ".result.pane.tab_id" "$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"

echo "== close: what is never closed =="
c lane new --repo "$C_REPO" --lane inv-1 --pattern investigate --idea x --workspace w2 >/dev/null
cnode --lane inv-1 --node investigate --status "done" --result pass --tab w2:t1
cst "w2:t1" '.tabs["w2:t1"].number = 1'
out="$(cd_ --lane inv-1)"
check "the lane's first tab is never closed" "KEEP investigate (first tab of its workspace)" "$out"
cnode --lane inv-1 --node investigate --status "done" --tab w9:t2
cst "w9:t2"
out="$(cd_ --lane inv-1)"
check "a tab outside the lane's workspace is never closed" "KEEP investigate (tab w9:t2 is not in the lane's workspace w2)" "$out"
check_absent "neither is closed" "tab close" "$(cat "$C_TMP/calls.log")"
cnode --lane inv-1 --node investigate --status blocked --tab w2:t2
cst "w2:t2"
check "a blocked node is kept" "KEEP investigate (blocked)" "$(cd_ --lane inv-1)"
cnode --lane inv-1 --node investigate --status "done" --tab w2:t5
cst ""
out="$(cd_ --lane inv-1)"
check "a tab that is already gone is reported and recorded" "GONE investigate w2:t5" "$out"
check "the gone tab counts as closed" "true" "$(clf '.nodes.investigate.tab_closed' inv-1)"
check_absent "a gone tab is not closed" "tab close" "$(cat "$C_TMP/calls.log")"
out="$(cd_ --lane nope 2>&1)"; rc=$?
check_rc "an unknown lane is refused" 6 "$rc"
out="$(cd_ 2>&1)"; rc=$?
check_rc "--lane is required" 2 "$rc"

echo "== close: the skill closes tabs at the right moments =="
orch="$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
check "orchestrate: records the tab of each agent node" "--tab <its tab id>" "$orch"
check "orchestrate: runs close-done after each node record" "close-done.sh --lane L --repo R" "$orch"
check "orchestrate: closes every agent tab at lane done" "at lane done" "$orch"

rm -rf "$C_TMP"
unset XDG_CONFIG_HOME
unset -f c c_herdr cst clf cnode cd_
