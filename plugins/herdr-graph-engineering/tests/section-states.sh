#!/usr/bin/env bash
# section-states.sh -- sourced by run-tests.sh; do not run standalone.
# A lane's states. A merged, finished lane stays in DONE, with its worktree and agent, also
# while its cleanup question is open. It moves to CLOSED only when the user says yes and
# cleanup.sh run removes the worktree. Nothing closes it by itself.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

U_TMP="$(mktemp -d)"
U_REPO="$U_TMP/repo"
git init -q -b main "$U_REPO" && git -C "$U_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf '.env\n' >>"$U_REPO/.git/info/exclude"
export XDG_CONFIG_HOME="$U_TMP/config"
u() { local s="$1"; shift; (cd "$U_REPO" && env -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_PLUGIN_ID PATH="$FIX/stub-herdr:$FIX/stub-gh:$PATH" HERDR_STUB_DIR="$U_TMP" GH_STUB_DIR="$U_TMP" HERDR_ENV=1 NO_COLOR=1 bash "$PLUGIN/scripts/$s.sh" "$@"); }
U_DIR="$U_REPO/.git/herdr-graph"
ulf() { if [ -f "$U_DIR/$1.yaml" ]; then printf '%s' "$U_DIR/$1.yaml"; else printf '%s' "$U_DIR/closed/$1.yaml"; fi; }
ul() { yq -r "$2" "$(ulf "$1")"; }
ust() { printf '%s' "$1" >"$U_TMP/state.json"; : >"$U_TMP/calls.log"; }
ugh() { printf '%s' "$1" >"$U_TMP/gh.json"; }
upr() { jq -cn --argjson n "$1" --arg b "$2" --arg s "$3" --arg h "${4:-}" '{number: $n, url: "https://github.com/o/r/pull/\($n)", state: $s, isDraft: false, reviewDecision: "", headRefName: $b, headRefOid: $h, createdAt: "2999-01-01T00:00:00Z"}'; }
uopen() { ul "$1" '[(.questions // [])[] | select(.answer == null) | .text] | join(" | ")'; }
usec() { u status --json --repo "$U_REPO" | jq -r --arg l "$1" '.[] | select(.lane == $l) | .section'; }
isfile() { [ -f "$1" ] && echo 1 || echo 0; }
isdir() { [ -d "$1" ] && echo 1 || echo 0; }
ucalls() { cat "$U_TMP/calls.log"; }
# an agent as herdr lists it: name, workspace, kind, state, session id
uag() { jq -cn --arg n "$1" --arg w "$2" --arg k "$3" --arg s "$4" --arg id "$5" --arg cwd "$U_TMP/wt-${2#w-}" \
    '{($n): ({name: $n, pane_id: "\($w):\($n)", workspace_id: $w, agent: $k, agent_status: $s, cwd: $cwd}
        + (if $id != "" then {agent_session: {source: "x", agent: $k, kind: "id", value: $id}} else {} end))}'; }
uagents() { jq -cs '{agents: (add // {})}'; }
# a solo lane on its own worktree, every node done, its pull request recorded; status stays open
ulane() { # lane pr-number
    git -C "$U_REPO" worktree add -q -b "feat/$1" "$U_TMP/wt-$1" main
    git -C "$U_TMP/wt-$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m work
    u lane new --repo "$U_REPO" --lane "$1" --pattern solo --idea "idea of $1" --gate true --branch "feat/$1" --workspace "w-$1" --owner graph >/dev/null
    u lane node --repo "$U_REPO" --lane "$1" --node impl --status "done" --result pass --agent "claude-$1" >/dev/null
    u lane node --repo "$U_REPO" --lane "$1" --node tests --status "done" --result pass >/dev/null
    u lane set --repo "$U_REPO" --lane "$1" --key pr --value "https://github.com/o/r/pull/$2" >/dev/null
}
umerged() { # lane pr-number [state]
    ugh "{\"https://github.com/o/r/pull/$2\": $(upr "$2" "feat/$1" "${3:-MERGED}" "$(git -C "$U_TMP/wt-$1" rev-parse HEAD)")}"
}
urow() { grep -n -- "$1" <<<"$(u panel --frame --width 90)" | head -1 | cut -d: -f1; }
uclick() { printf '\033[<0;%s;%sM\033[<0;%s;%sm' "$1" "$2" "$1" "$2"; }
ust '{}'; ugh '{}'

echo "== DONE: a merged, finished lane stays =="
ulane a 1
umerged a 1
u lane done-extra --repo "$U_REPO" --lane a --text "live check after a restart" >/dev/null
ust "$(uag claude-a w-a claude idle sess-a | uagents)"
jq -cn --argjson p "$(upr 1 feat/a MERGED)" '{fetched: 1, lanes: {a: [$p]}}' >"$U_DIR/prs.json"
check "before any check it is in DONE, though a criterion is open" "done" "$(usec a)"
out="$(u cleanup check --repo "$U_REPO" --lane a 2>&1)"
check "the check asks the cleanup question" "CLEANUP a" "$out"
check "its status is done" "done" "$(ul a .status)"
check "it stays in DONE while the question is open" "done" "$(usec a)"
check "checked again it only waits" "PENDING a" "$(u cleanup check --repo "$U_REPO" --lane a 2>&1)"
check "the lane stays open" "1" "$(isfile "$U_DIR/a.yaml")"
check_absent "its workspace is not closed" "workspace close" "$(ucalls)"
check_absent "no tab is closed" "tab close" "$(ucalls)"
check_absent "no worktree is removed" "worktree remove" "$(ucalls)"
check "its agent is not hidden" "claude-a" "$(PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$U_TMP" herdr agent list)"
frame="$(u panel --frame --width 90)"
check "the panel shows DONE" "DONE" "$frame"
check "with the open criterion" "open: live check after a restart" "$frame"
check_absent "nothing is under NEEDS YOU" "NEEDS YOU" "$frame"
u session set --key orchestrator --value graph >/dev/null
u notify reconcile --session graph >/dev/null 2>&1
check "the orchestrator is still told" "cleanup-ready" "$(u notify list --session graph)"
events="$XDG_STATE_HOME/herdr-graph/sessions/graph.events.json"
jq '(.open // {})[] |= (.manual = true)' "$events" >"$events.tmp" && mv "$events.tmp" "$events"
check "an unanswered cleanup question never moves it to NEEDS YOU" "done" "$(usec a)"
echo x >"$U_TMP/wt-a/scratch.txt"
check "a dirty checkout is reported" "BLOCKED a" "$(u cleanup check --repo "$U_REPO" --lane a 2>&1)"
check "and the lane stays in DONE" "done" "$(usec a)"
rm "$U_TMP/wt-a/scratch.txt"
u cleanup check --repo "$U_REPO" --lane a >/dev/null 2>&1
u lane ask --repo "$U_REPO" --lane a --kind agent --text "which name?" >/dev/null
check "an agent's question still needs the user" "needs" "$(usec a)"
u lane answer --repo "$U_REPO" --lane a --id "$(ul a '[.questions[] | select(.answer == null and .kind == "agent") | .id][0]')" --text either >/dev/null
check "answered: back in DONE" "done" "$(usec a)"

echo "== DONE: the panel's [x] only asks the orchestrator =="
ust "$(uag graph w-graph claude idle "" | uagents)"
r="$(urow "a  solo")"
{ uclick 88 "$r"; uclick 82 "$r"; } | u panel --frame --width 90 --feed >/dev/null
check "the panel asks the owner" "agent prompt graph Clean up lane a" "$(ucalls)"
check "and moves nothing" "1" "$(isfile "$U_DIR/a.yaml")"
check "the worktree stays" "1" "$(isdir "$U_TMP/wt-a")"

echo "== DONE to CLOSED: only on the recorded yes =="
ust '{}'
check "without a yes it is refused" "NOT CONFIRMED" "$(u cleanup run --repo "$U_REPO" --lane a 2>&1)"
u lane set --repo "$U_REPO" --lane a --key cleanup --value confirmed >/dev/null
out="$(u cleanup run --repo "$U_REPO" --lane a 2>&1)"; rc=$?
check_rc "with the yes it runs" 0 "$rc"
check "through herdr" "worktree remove --workspace w-a" "$(ucalls)"
check_absent "never forced" "--force" "$(ucalls)"
check "the lane is in CLOSED" "closed" "$(usec a)"
check "the branch is kept" "feat/a" "$(git -C "$U_REPO" branch --list feat/a)"

echo "== states: unmerged and unfinished lanes do not move =="
ulane notyet 3
umerged notyet 3 OPEN
u cleanup check --repo "$U_REPO" --lane notyet >/dev/null 2>&1
check "an open pull request leaves the status open" "open" "$(ul notyet .status)"
ulane unfinished 4
umerged unfinished 4
u lane node --repo "$U_REPO" --lane unfinished --node tests --status waiting >/dev/null
check "a merge before every node is its own question" "MERGED-EARLY unfinished" "$(u cleanup check --repo "$U_REPO" --lane unfinished 2>&1)"

echo "== states: a side pull request is a note, not a question =="
git -C "$U_REPO" worktree add -q -b feat/side "$U_TMP/wt-side" main
u lane new --repo "$U_REPO" --lane side --pattern solo --idea x --gate true --branch feat/side --workspace w-side --owner graph >/dev/null
jq -cn --argjson p "$(upr 80 feat/side MERGED)" '{fetched: 1, lanes: {side: [$p]}}' >"$U_DIR/prs.json"
ugh "{\"https://github.com/o/r/pull/80\": $(upr 80 feat/side MERGED)}"
ust '{}'
check_absent "it does not need the user, before any check" "merged" "$(u status --json --repo "$U_REPO" | jq -r '.[] | select(.lane == "side") | .attention | join(" ")')"
check "check notes it" "SIDE-MERGE side" "$(u cleanup check --repo "$U_REPO" --lane side 2>&1)"
check "as a lane note" "https://github.com/o/r/pull/80" "$(ul side '[.notes[].text] | join(" | ")')"
check "no question stays" "" "$(uopen side)"
check "the lane keeps working" "working" "$(usec side)"
u cleanup check --repo "$U_REPO" --lane side >/dev/null 2>&1
check "noted once" "1" "$(ul side '.notes | length')"
check "the sweep checks a lane with a merged pull request on its branch" 'any(.prs[]; .state == "MERGED")' "$(cat "$PLUGIN/scripts/src/events.sh")"

echo "== states: no automatic close is left =="
check_rc "there is no autoclose on/off key" 2 "$(u session set --key autoclose --value on >/dev/null 2>&1; echo $?)"
check_absent "no script closes a lane by itself" "auto_close" "$(cat "$PLUGIN"/scripts/*.sh "$PLUGIN"/scripts/src/*.sh)"
orch="$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
check "orchestrate: a finished lane stays in DONE" "stays in DONE" "$orch"
check "orchestrate: a side merge is a note" "SIDE-MERGE" "$orch"
check_absent "orchestrate: no automatic close" "AUTOCLOSE" "$orch"
check_absent "README: no toggle for it" "--key autoclose" "$(cat "$PLUGIN/README.md")"

git -C "$U_REPO" worktree prune 2>/dev/null
rm -rf "$U_TMP"
unset XDG_CONFIG_HOME
unset -f u ulf ul ust ugh upr uopen usec isfile isdir ucalls uag uagents ulane umerged urow uclick
