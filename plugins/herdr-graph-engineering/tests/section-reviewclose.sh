#!/usr/bin/env bash
# section-reviewclose.sh -- sourced by run-tests.sh; do not run standalone.
# A review lane is ready to close once it posted (or the user decided not to post) or its
# findings were forwarded, without waiting for the reviewed pull request to merge; cleanup.sh
# offers to forward the findings to the agent that owns the reviewed pull request.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

R_TMP="$(mktemp -d)"
RA="$R_TMP/repo-a" RB="$R_TMP/repo-b"
for r in "$RA" "$RB"; do
    git init -q -b main "$r" && git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
done
rk() { local s="$1"; shift; (cd "$RA" && env -u HERDR_PANE_ID PATH="$FIX/stub-herdr:$FIX/stub-gh:$PATH" HERDR_STUB_DIR="$R_TMP" GH_STUB_DIR="$R_TMP" HERDR_ENV=1 XDG_CONFIG_HOME="$R_TMP/config" bash "$PLUGIN/scripts/$s.sh" "$@"); }
# repository B (the reviewed work) has a workspace open in Herdr; its implementer may be live
rst() { # live agents json
    printf '{"workspaces":[{"workspace_id":"w-b","worktree":{"repo_root":"%s"}}],"agents":%s}' "$RB" "$1" >"$R_TMP/state.json"
    : >"$R_TMP/calls.log"
}
rlf() { local f; f="$(git -C "$RA" rev-parse --path-format=absolute --git-common-dir)/herdr-graph"
    if [ -f "$f/$2.yaml" ]; then yq -r "$1" "$f/$2.yaml"; else yq -r "$1" "$f/closed/$2.yaml"; fi; }
U9="https://github.com/o/r/pull/9" U10="https://github.com/o/r/pull/10" U12="https://github.com/o/r/pull/12"
printf '{"%s": {"number": 9, "url": "%s", "headRefName": "feat/x", "state": "OPEN"}, "%s": {"number": 12, "url": "%s", "headRefName": "feat/other", "state": "OPEN"}}' \
    "$U9" "$U9" "$U12" "$U12" >"$R_TMP/gh.json"
# a review lane on its own clean worktree, still open
rlane() { # lane, pr number, lane.sh new args...
    local l="$1" n="$2"
    shift 2
    git -C "$RA" worktree add -q -b "look/pr-$n" "$R_TMP/wt-$l" main
    rk lane new --repo "$RA" --lane "$l" --idea "review $n" --branch "look/pr-$n" --workspace "w-$l" "$@" >/dev/null
}
rnode() { rk lane node --repo "$RA" --lane "$1" --node "$2" --status "$3" ${4:+--result "$4"} >/dev/null; }
rst '{}'

echo "== review close: lane.sh forwarded =="
rlane rev-9 9 --pattern review --input pr="$U9"
out="$(rk lane set --repo "$RA" --lane rev-9 --key forwarded --value maybe 2>&1)"; rc=$?
check_rc "forwarded takes only LANE/AGENT or declined" 2 "$rc"
check "and says so" "forwarded must be LANE/AGENT or declined" "$out"

echo "== review close: ready once posted, without a merge =="
out="$(rk cleanup check --repo "$RA" 2>&1)"
check_absent "a review lane that has not posted is not ready" "rev-9" "$out"
rnode rev-9 review "done" pass
rnode rev-9 approve "done" pass
rnode rev-9 post "done" pass
out="$(rk cleanup check --repo "$RA" 2>&1)"
check "a posted review lane is ready while still open" "CLEANUP rev-9 (review lane: its review was posted" "$out"
check_absent "the reviewed pull request is not asked for its merge state" "pr view $U9 --json state" "$(cat "$R_TMP/gh.log")"
check_absent "nobody owns the reviewed pull request: nothing to forward" "FORWARD" "$out"

# the reviewed pull request's branch is an open lane in repository B; its implementer is gone
rk lane new --repo "$RB" --lane own-x --pattern solo --idea "build x" --gate t --branch feat/x >/dev/null
rk lane node --repo "$RB" --lane own-x --node impl --status "done" --result pass --agent claude-own-x-impl >/dev/null
check "an owner whose agent is gone is shown with -" "FORWARD rev-9 $U9 $RB own-x - impl" "$(rk cleanup check --repo "$RA" 2>&1)"
# now it is live
rk lane set --repo "$RA" --lane rev-9 --key cleanup --value "" >/dev/null
rk lane answer --repo "$RA" --lane rev-9 --text "asked again below" >/dev/null
rst '{"a1": {"name": "claude-own-x-impl", "pane_id": "w-b:p2", "agent_status": "idle"}}'
out="$(rk cleanup check --repo "$RA" 2>&1)"
check "the owner of the reviewed pull request is offered the findings" "FORWARD rev-9 $U9 $RB own-x claude-own-x-impl impl" "$out"
q="$(rlf '.question' rev-9)"
check "the close question asks to send the findings first" "Send the findings of review rev-9 on $U9 to own-x/claude-own-x-impl" "$q"
check "and still asks to close the lane" "close the lane?" "$q"
check "the user is notified" "notification show rev-9 needs you" "$(cat "$R_TMP/calls.log")"
check "the lane is in DONE with the question" "DONE (1)" "$(rk status --text --repo "$RA")"
out="$(rk cleanup check --repo "$RA" 2>&1)"
check "the close question is not asked twice" "PENDING rev-9" "$out"
check "the forward offer stays until it is decided" "FORWARD rev-9 $U9" "$out"
rk lane set --repo "$RA" --lane rev-9 --key forwarded --value own-x/claude-own-x-impl >/dev/null
check "forwarding is in the lane's history" "forwarded = own-x/claude-own-x-impl" "$(rlf '.history | join("\n")' rev-9)"
out="$(rk cleanup check --repo "$RA" 2>&1)"
check_absent "a forwarded lane is not offered again" "FORWARD" "$out"

echo "== review close: the user decided not to post =="
rlane rev-10 10 --pattern review --input pr="$U10"
rnode rev-10 review "done" pass
rnode rev-10 approve "done" fail
out="$(rk cleanup check --repo "$RA" --lane rev-10 2>&1)"
check "a review the user decided not to post is ready" "CLEANUP rev-10 (review lane: the user decided not to post" "$out"
rk lane set --repo "$RA" --lane rev-10 --key forwarded --value declined >/dev/null
check_absent "a declined forward is not offered" "FORWARD" "$(rk cleanup check --repo "$RA" --lane rev-10 2>&1)"

echo "== review close: forwarded before posting =="
rlane rev-11 11 --pattern review --input pr="$U9"
rnode rev-11 review "done" pass
out="$(rk cleanup check --repo "$RA" --lane rev-11 2>&1)"
check_absent "a review still waiting for its approval is not ready" "rev-11" "$out"
rk lane set --repo "$RA" --lane rev-11 --key forwarded --value declined >/dev/null
check_absent "declining the forward alone does not finish it" "rev-11" "$(rk cleanup check --repo "$RA" --lane rev-11 2>&1)"
rk lane set --repo "$RA" --lane rev-11 --key forwarded --value own-x/claude-own-x-impl >/dev/null
check "a review whose findings were forwarded is ready" "CLEANUP rev-11 (review lane: its findings were forwarded to own-x/claude-own-x-impl" "$(rk cleanup check --repo "$RA" --lane rev-11 2>&1)"

echo "== review close: a review stack offers each reviewed pull request's owner =="
rk make-review-stack --pr "$U9" --pr "$U12" --out "$R_TMP/stack.yaml" >/dev/null
rlane stack-1 91 --pattern-file "$R_TMP/stack.yaml"
for n in review-1 review-2 cross approve post-1 post-2; do rnode stack-1 "$n" "done" pass; done
out="$(rk cleanup check --repo "$RA" --lane stack-1 2>&1)"
check "a posted review stack is ready" "CLEANUP stack-1 (review lane: its review was posted" "$out"
check "the owner of a stacked pull request is offered the findings" "FORWARD stack-1 $U9 $RB own-x claude-own-x-impl impl" "$out"
check_absent "a pull request nobody owns offers nothing" "FORWARD stack-1 $U12" "$out"

echo "== review close: run closes an open review lane after a yes =="
rk lane answer --repo "$RA" --lane rev-11 --text yes >/dev/null
rk lane set --repo "$RA" --lane rev-11 --key cleanup --value confirmed >/dev/null
out="$(rk cleanup run --repo "$RA" --lane rev-11 2>&1)"; rc=$?
check_rc "cleanup run accepts a finished review lane that is still open" 0 "$rc"
check "its worktree is removed" "worktree remove --workspace w-rev-11" "$(cat "$R_TMP/calls.log")"
check "and the lane is closed" "closed" "$(rlf '.status' rev-11)"
rk lane new --repo "$RA" --lane solo-1 --pattern solo --idea x --gate t >/dev/null
rk lane set --repo "$RA" --lane solo-1 --key cleanup --value "" >/dev/null
out="$(rk cleanup run --repo "$RA" --lane solo-1 2>&1)"; rc=$?
check_rc "run still refuses an open lane that is not a finished review" 6 "$rc"

echo "== review close: the skill forwards findings through review-owner.sh =="
orch="$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
check "orchestrate: a FORWARD line is handled" "FORWARD <lane>" "$orch"
check "orchestrate: the forward question" "Send the N findings of review" "$orch"
check "orchestrate: the Prompt for AI Agents block is sent" "Prompt for AI Agents" "$orch"
check "orchestrate: the owner's node is reopened" "--status running --agent <agent>" "$orch"
check "orchestrate: the forward is recorded" "--key forwarded --value <owner lane>/<agent>" "$orch"
check "orchestrate: a no is recorded" "--key forwarded --value declined" "$orch"
check "orchestrate: the owner lookup is the script" "review-owner.sh --pr" "$orch"
check "readme: review lanes close without a merge" "review-owner.sh" "$(cat "$PLUGIN/README.md")"

for w in "$R_TMP"/wt-*; do git -C "$RA" worktree remove --force "$w" 2>/dev/null; done
git -C "$RA" worktree prune 2>/dev/null
rm -rf "$R_TMP"
unset -f rk rst rlf rlane rnode
