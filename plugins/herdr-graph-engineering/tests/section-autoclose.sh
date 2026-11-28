#!/usr/bin/env bash
# section-autoclose.sh -- sourced by run-tests.sh; do not run standalone.
# A merged, finished lane closes by itself: its workspace closes (the agents leave Herdr), a
# restore note is recorded, the worktree and branch stay. Only removing the worktree waits for
# the user ([x] on CLOSED, or cleanup.sh remove). A side pull request is only a note.
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
# an agent as herdr lists it: name, workspace, kind, state, session id
uag() { jq -cn --arg n "$1" --arg w "$2" --arg k "$3" --arg s "$4" --arg id "$5" --arg cwd "$U_TMP/wt-${2#w-}" \
    '{($n): ({name: $n, pane_id: "\($w):\($n)", workspace_id: $w, agent: $k, agent_status: $s, cwd: $cwd}
        + (if $id != "" then {agent_session: {source: "x", agent: $k, kind: "id", value: $id}} else {} end))}'; }
uagents() { jq -cs '{agents: (add // {})}'; }
# a solo lane on its own worktree, every node done, its pull request recorded; status stays open
ulane() { # lane pr-number
    git -C "$U_REPO" worktree add -q -b "feat/$1" "$U_TMP/wt-$1" main
    git -C "$U_TMP/wt-$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m work
    u lane new --repo "$U_REPO" --lane "$1" --pattern solo --idea x --gate true --branch "feat/$1" --workspace "w-$1" --owner graph >/dev/null
    u lane node --repo "$U_REPO" --lane "$1" --node impl --status "done" --result pass --agent "claude-$1" >/dev/null
    u lane node --repo "$U_REPO" --lane "$1" --node tests --status "done" --result pass >/dev/null
    u lane set --repo "$U_REPO" --lane "$1" --key pr --value "https://github.com/o/r/pull/$2" >/dev/null
}
umerged() { # lane pr-number [state]
    ugh "{\"https://github.com/o/r/pull/$2\": $(upr "$2" "feat/$1" "${3:-MERGED}" "$(git -C "$U_TMP/wt-$1" rev-parse HEAD)")}"
}
ust '{}'; ugh '{}'

echo "== autoclose: a merged, finished lane closes by itself =="
ulane done-a 1
umerged done-a 1
u lane done-extra --repo "$U_REPO" --lane done-a --text "live check after a restart" >/dev/null
u lane ask --repo "$U_REPO" --lane done-a --kind cleanup --text "Cleanup done-a: remove it?" >/dev/null
u lane set --repo "$U_REPO" --lane done-a --key cleanup --value ready >/dev/null
ust "$({ uag claude-done-a w-done-a claude idle sess-a; uag helper-codex w-other codex idle sess-o; } | uagents)"
u lane node --repo "$U_REPO" --lane done-a --node tests --status "done" --result pass >/dev/null
out="$(u cleanup check --repo "$U_REPO" --lane done-a 2>&1)"
check "it closes, though the lane is still open and a done criterion is unmet" "AUTOCLOSED done-a" "$out"
check "the lane is in closed/" "1" "$(isfile "$U_DIR/closed/done-a.yaml")"
check "its workspace is closed" "workspace close w-done-a" "$(cat "$U_TMP/calls.log")"
check_absent "so its agent left Herdr" "claude-done-a" "$(PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$U_TMP" herdr agent list)"
check_absent "no worktree is removed" "worktree remove" "$(cat "$U_TMP/calls.log")"
check_absent "a workspace group is never closed" "--group" "$(cat "$U_TMP/calls.log")"
check "the worktree stays" "1" "$(isdir "$U_TMP/wt-done-a")"
check "the branch stays" "feat/done-a" "$(git -C "$U_REPO" branch --list feat/done-a)"
check "the restore note has the workspace path" "$U_TMP/wt-done-a" "$(ul done-a .restore.workspace_path)"
check "the agent's session id" "sess-a" "$(ul done-a '.restore.agents[0].session_id')"
check "and its resume command" "claude --resume sess-a" "$(ul done-a '.restore.agents[0].resume')"
check "read from herdr agent get" "agent get claude-done-a" "$(cat "$U_TMP/calls.log")"
check "a lane note names the open criterion" "open done criteria: live check after a restart" "$(ul done-a '[.notes[].text] | join(" | ")')"
check "the cleanup question is withdrawn" "" "$(uopen done-a)"
check "the user is told" "notification show done-a closed" "$(cat "$U_TMP/calls.log")"
check "status --json lists it under CLOSED" "closed" "$(usec done-a)"
check "with the open criterion" "live check after a restart" "$(u status --json --repo "$U_REPO" | jq -r '.[] | select(.lane == "done-a") | .open_criteria[]')"
check "the panel's CLOSED entry shows it" "open: live check after a restart" "$(u panel --frame --width 90)"
check_absent "nothing needs the user" "NEEDS YOU" "$(u status --text --repo "$U_REPO")"

echo "== autoclose: resume commands for Codex and OpenCode =="
ulane done-b 2
umerged done-b 2
u lane node --repo "$U_REPO" --lane done-b --node tests --status "done" --result pass --agent opencode-done-b >/dev/null
ust "$({ uag claude-done-b w-done-b codex done thread-b; uag opencode-done-b w-done-b opencode idle ses_b; } | uagents)"
u cleanup check --repo "$U_REPO" --lane done-b >/dev/null 2>&1
res="$(ul done-b '[.restore.agents[].resume] | join(" | ")')"
check "Codex" "codex resume thread-b" "$res"
check "OpenCode" "opencode --session ses_b" "$res"

echo "== autoclose: a tab closed at lane done keeps its agent's session =="
ulane tabbed 3
umerged tabbed 3
u lane node --repo "$U_REPO" --lane tabbed --node impl --status "done" --result pass --tab w-tabbed:t2 >/dev/null
u lane set --repo "$U_REPO" --lane tabbed --key status --value "done" >/dev/null
ust "$(uag claude-tabbed w-tabbed claude idle sess-t | uagents | jq -c '. + {tabs: {"w-tabbed:t2": {tab_id: "w-tabbed:t2", workspace_id: "w-tabbed", number: 2, agent_status: "idle"}}}')"
u close-done --repo "$U_REPO" --lane tabbed >/dev/null 2>&1
check "close-done records the session before the tab goes" "sess-t" "$(ul tabbed .nodes.impl.session.value)"
ust '{}'
u cleanup check --repo "$U_REPO" --lane tabbed >/dev/null 2>&1
check "and the restore note uses it once the agent is gone" "claude --resume sess-t" "$(ul tabbed '.restore.agents[0].resume')"

echo "== autoclose: it waits for what is still running or asked =="
ulane busy 4
umerged busy 4
ust "$(uag claude-busy w-busy claude working s | uagents)"
out="$(u cleanup check --repo "$U_REPO" --lane busy 2>&1)"
check "a working agent keeps the lane open" "AUTOCLOSE-WAIT busy (agent claude-busy is working)" "$out"
check_absent "and its workspace" "workspace close" "$(cat "$U_TMP/calls.log")"
check "no cleanup question is asked" "" "$(uopen busy)"
check_absent "and it does not need the user" "needs" "$(usec busy)"
ust "$(uag claude-busy w-busy claude blocked s | uagents)"
u cleanup check --repo "$U_REPO" --lane busy >/dev/null 2>&1
check "a blocked agent does need the user" "needs" "$(usec busy)"
ust "$(uag claude-busy w-busy claude idle s | uagents)"
u lane ask --repo "$U_REPO" --lane busy --kind agent --text "which name?" >/dev/null
out="$(u cleanup check --repo "$U_REPO" --lane busy 2>&1)"
check "an open question keeps it open" "AUTOCLOSE-WAIT busy (an open question waits for the user)" "$out"
u lane answer --repo "$U_REPO" --lane busy --text "either" >/dev/null
check "then it closes" "AUTOCLOSED busy" "$(u cleanup check --repo "$U_REPO" --lane busy 2>&1)"
ulane unfinished 5
umerged unfinished 5
u lane node --repo "$U_REPO" --lane unfinished --node tests --status waiting >/dev/null
ust '{}'
out="$(u cleanup check --repo "$U_REPO" --lane unfinished 2>&1)"
check "its own pull request merged before every node: still its own question" "MERGED-EARLY unfinished" "$out"
check "the lane stays open" "1" "$(isfile "$U_DIR/unfinished.yaml")"
ulane notyet 6
umerged notyet 6 OPEN
u cleanup check --repo "$U_REPO" --lane notyet >/dev/null 2>&1
check "an open pull request never closes a lane" "1" "$(isfile "$U_DIR/notyet.yaml")"

echo "== autoclose: a shared workspace stays =="
ulane shared 7
umerged shared 7
ust "$({ uag claude-shared w-shared claude idle s; uag stranger w-shared claude idle x; } | uagents)"
out="$(u cleanup check --repo "$U_REPO" --lane shared 2>&1)"
check "the lane closes" "AUTOCLOSED shared" "$out"
check_absent "a workspace with another agent is not closed" "workspace close" "$(cat "$U_TMP/calls.log")"
check "and the note says why" "agent stranger" "$(ul shared '.restore.workspace_kept')"
ulane mine 8
umerged mine 8
ust '{}'
(cd "$U_REPO" && PATH="$FIX/stub-herdr:$FIX/stub-gh:$PATH" HERDR_STUB_DIR="$U_TMP" GH_STUB_DIR="$U_TMP" HERDR_WORKSPACE_ID=w-mine bash "$PLUGIN/scripts/cleanup.sh" check --repo "$U_REPO" --lane mine >/dev/null 2>&1)
check_absent "the caller's own workspace is never closed" "workspace close" "$(cat "$U_TMP/calls.log")"
ulane refused 9
umerged refused 9
ust '{"workspace_close": "fail"}'
out="$(u cleanup check --repo "$U_REPO" --lane refused 2>&1)"
check "a workspace Herdr will not close keeps the lane open" "AUTOCLOSE-WAIT refused" "$out"
check "the lane file stays" "1" "$(isfile "$U_DIR/refused.yaml")"

echo "== autoclose: work left in the worktree is kept and named =="
ulane leftover 10
umerged leftover 10
echo x >"$U_TMP/wt-leftover/notes.txt"
ust '{}'
check "a dirty checkout is kept, so the lane still closes" "AUTOCLOSED leftover" "$(u cleanup check --repo "$U_REPO" --lane leftover 2>&1)"
check "the note names what is left" "uncommitted changes" "$(ul leftover '[.notes[].text] | join(" | ")')"

echo "== autoclose: a finished review closes =="
git -C "$U_REPO" worktree add -q -b look/pr-70 "$U_TMP/wt-rev" main
u lane new --repo "$U_REPO" --lane rev --pattern review --idea x --input pr=https://github.com/o/r/pull/70 --branch look/pr-70 --workspace w-rev >/dev/null
for n in review approve post; do u lane node --repo "$U_REPO" --lane rev --node "$n" --status "done" --result pass >/dev/null; done
ust '{}'
check "a posted review closes with no merge" "AUTOCLOSED rev" "$(u cleanup check --repo "$U_REPO" --lane rev 2>&1)"

echo "== autoclose: the session can turn it off =="
u session set --key autoclose --value off >/dev/null
check "the toggle lives in the session file" "off" "$(yq -r .autoclose "$XDG_STATE_HOME/herdr-graph/sessions/graph.yaml")"
check_rc "it takes only on or off" 2 "$(u session set --key autoclose --value maybe >/dev/null 2>&1; echo $?)"
ulane manual 11
umerged manual 11
u lane set --repo "$U_REPO" --lane manual --key status --value "done" >/dev/null
ust '{}'
out="$(u cleanup check --repo "$U_REPO" --lane manual 2>&1)"
check "off: the cleanup question is asked as before" "CLEANUP manual" "$out"
check "off: the lane stays open" "1" "$(isfile "$U_DIR/manual.yaml")"
u session set --key autoclose --value on >/dev/null
check "on again: it closes" "AUTOCLOSED manual" "$(u cleanup check --repo "$U_REPO" --lane manual 2>&1)"

echo "== autoclose: the feedback loop is collected first =="
u session set --key feedback --value on >/dev/null
ulane notes 12
umerged notes 12
ust '{}'
out="$(u cleanup check --repo "$U_REPO" --lane notes 2>&1)"
check "feedback is due before it closes" "FEEDBACK notes" "$out"
check "the lane stays open" "1" "$(isfile "$U_DIR/notes.yaml")"
check "and records what it waits for" "feedback-due" "$(ul notes .cleanup)"
check_absent "without needing the user" "needs" "$(usec notes)"
u session set --key orchestrator --value graph >/dev/null
u notify reconcile --session graph >/dev/null 2>&1
check "the orchestrator is woken for it" "notes/- feedback-due" "$(u notify list --session graph)"
u feedback add --from orchestrator --lane notes --text "nothing to add" >/dev/null
check "with the note written it closes" "AUTOCLOSED notes" "$(u cleanup check --repo "$U_REPO" --lane notes 2>&1)"
u session set --key feedback --value off >/dev/null

echo "== autoclose: the panel's restore brings it back for good =="
ust '{}'
out="$(u lane restore --repo "$U_REPO" --lane done-a)"
check "restore offers the resume command" "RESUME claude-done-a: cd $U_TMP/wt-done-a && claude --resume sess-a" "$out"
check "the lane is back" "1" "$(isfile "$U_DIR/done-a.yaml")"
out="$(u cleanup check --repo "$U_REPO" --lane done-a 2>&1)"
check_absent "a restored lane is not closed again" "AUTOCLOSED" "$out"
check "nor asked about" "" "$(uopen done-a)"
check_absent "and does not need the user" "needs" "$(usec done-a)"
check "its panel entry keeps the resume command" "claude --resume sess-a" "$(u panel --frame --width 120)"
u lane close --repo "$U_REPO" --lane done-a >/dev/null

echo "== autoclose: removing the worktree waits for the user =="
echo x >"$U_TMP/wt-done-a/scratch.txt"
ust '{}'
out="$(u cleanup remove --repo "$U_REPO" --lane done-a 2>&1)"; rc=$?
check_rc "a dirty worktree is not removed" 6 "$rc"
check "and says why" "uncommitted changes" "$out"
check "it stays" "1" "$(isdir "$U_TMP/wt-done-a")"
rm "$U_TMP/wt-done-a/scratch.txt"
echo SECRET >"$U_TMP/wt-done-a/.env"
out="$(u cleanup remove --repo "$U_REPO" --lane done-a 2>&1)"; rc=$?
check_rc "ignored files that would be lost stop it" 6 "$rc"
check "and are named" ".env" "$out"
out="$(u cleanup remove --repo "$U_REPO" --lane done-a --lose-ignored 2>&1)"; rc=$?
check_rc "with the user's yes to lose them it removes" 0 "$rc"
check "the worktree is gone" "0" "$(isdir "$U_TMP/wt-done-a")"
check "the branch is kept" "feat/done-a" "$(git -C "$U_REPO" branch --list feat/done-a)"
check "an open lane is never removed this way" "NOT CLOSED" "$(u cleanup remove --repo "$U_REPO" --lane notyet 2>&1)"
ust "{\"workspaces\": [{\"workspace_id\": \"w-shared\", \"worktree\": {\"repo_root\": \"$U_REPO\", \"checkout_path\": \"$U_TMP/wt-shared\"}}]}"
u cleanup remove --repo "$U_REPO" --lane shared >/dev/null 2>&1
check "a workspace still open on it is removed through herdr" "worktree remove --workspace w-shared" "$(cat "$U_TMP/calls.log")"
check_absent "never forced" "--force" "$(cat "$U_TMP/calls.log")"

echo "== autoclose: [x] on CLOSED removes the worktree =="
# only done-b's repository entry is clicked: clear the others first
for l in tabbed busy mine leftover rev manual notes shared; do u lane clear --repo "$U_REPO" --lane "$l" >/dev/null; done
ust '{}'
urow() { grep -n -- "$1" <<<"$(u panel --frame --width 90)" | head -1 | cut -d: -f1; }
uclick() { printf '\033[<0;%s;%sM\033[<0;%s;%sm' "$1" "$2" "$1" "$2"; }
r="$(urow "done-b  solo")"
out="$(uclick 88 "$r" | u panel --frame --width 90 --feed)"
check "the first click says what confirm removes" "removes its worktree" "$out"
echo x >"$U_TMP/wt-done-b/scratch.txt"
out="$( { uclick 88 "$r"; uclick 82 "$r"; } | u panel --frame --width 90 --feed)"
check "a worktree that cannot go keeps the entry" "1" "$(isfile "$U_DIR/closed/done-b.yaml")"
check "and the panel says why" "worktree kept" "$out"
rm "$U_TMP/wt-done-b/scratch.txt"
{ uclick 88 "$r"; uclick 82 "$r"; } | u panel --frame --width 90 --feed >/dev/null
check "confirm removes the worktree" "0" "$(isdir "$U_TMP/wt-done-b")"
check "and clears the entry" "1" "$(isfile "$U_DIR/closed/cleared/done-b.yaml")"

echo "== autoclose: a side pull request is a note, not a question =="
git -C "$U_REPO" worktree add -q -b feat/side "$U_TMP/wt-side" main
u lane new --repo "$U_REPO" --lane side --pattern solo --idea x --gate true --branch feat/side --workspace w-side --owner graph >/dev/null
jq -cn --argjson p "$(upr 80 feat/side MERGED)" '{fetched: 1, lanes: {side: [$p]}}' >"$U_DIR/prs.json"
ugh "{\"https://github.com/o/r/pull/80\": $(upr 80 feat/side MERGED)}"
u lane ask --repo "$U_REPO" --lane side --kind merged-early --text "Merged early: old question" >/dev/null
ust '{}'
check_absent "it does not need the user, before any check" "merged" "$(u status --json --repo "$U_REPO" | jq -r '.[] | select(.lane == "side") | .attention | join(" ")')"
out="$(u cleanup check --repo "$U_REPO" --lane side 2>&1)"
check "check notes it" "SIDE-MERGE side" "$out"
check "as a lane note" "https://github.com/o/r/pull/80" "$(ul side '[.notes[].text] | join(" | ")')"
check "no question stays" "" "$(uopen side)"
check "the lane keeps working" "working" "$(usec side)"
u cleanup check --repo "$U_REPO" --lane side >/dev/null 2>&1
check "noted once" "1" "$(ul side '.notes | length')"

echo "== autoclose: the sweep reaches a side merge =="
check "the sweep checks a lane with a merged pull request on its branch" 'any(.prs[]; .state == "MERGED")' "$(cat "$PLUGIN/scripts/src/events.sh")"

echo "== autoclose: the skill and the README say it =="
orch="$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
check "orchestrate: lanes close by themselves" "AUTOCLOSED" "$orch"
check "orchestrate: the toggle" "--key autoclose --value off" "$orch"
check "orchestrate: removal is the user's" 'cleanup.sh" remove --lane L' "$orch"
check "orchestrate: a side merge is a note" "SIDE-MERGE" "$orch"
check "orchestrate: the feedback-due event" '`feedback-due`' "$orch"
rd="$(cat "$PLUGIN/README.md")"
check "README: the toggle" "--key autoclose" "$rd"
check "README: removal" "cleanup.sh remove" "$rd"

git -C "$U_REPO" worktree prune 2>/dev/null
rm -rf "$U_TMP"
unset XDG_CONFIG_HOME
unset -f u ulf ul ust ugh upr uopen usec isfile isdir uag uagents ulane umerged urow uclick
