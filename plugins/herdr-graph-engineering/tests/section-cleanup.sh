#!/usr/bin/env bash
# section-cleanup.sh -- sourced by run-tests.sh; do not run standalone.
# cleanup.sh: finding lanes ready for cleanup, asking the user, and the one cleanup command.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

K_TMP="$(mktemp -d)"
K_REPO="$K_TMP/repo"
git init -q -b main "$K_REPO" && git -C "$K_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
export XDG_CONFIG_HOME="$K_TMP/config"
k() { local s="$1"; shift; PATH="$FIX/stub-herdr:$FIX/stub-gh:$PATH" HERDR_STUB_DIR="$K_TMP" GH_STUB_DIR="$K_TMP" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 bash "$PLUGIN/scripts/$s.sh" "$@"; }
kst() { printf '%s' "${1:-}" >"$K_TMP/state.json"; : >"$K_TMP/calls.log"; : >"$K_TMP/gh.log"; }
kgh() { printf '%s' "$1" >"$K_TMP/gh.json"; }
klf() { local f; f="$(git -C "$K_REPO" rev-parse --path-format=absolute --git-common-dir)/herdr-graph"
    if [ -f "$f/$2.yaml" ]; then yq -r "$1" "$f/$2.yaml"; else yq -r "$1" "$f/closed/$2.yaml"; fi; }
kc() { git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$2"; }
# a lane on its own worktree with one commit, done
klane() { # lane branch pattern [extra lane.sh new args]
    local lane="$1" br="$2" p="$3"
    shift 3
    git -C "$K_REPO" worktree add -q -b "$br" "$K_TMP/wt-$lane" main
    kc "$K_TMP/wt-$lane" "work on $lane"
    k lane new --repo "$K_REPO" --lane "$lane" --pattern "$p" --idea x --branch "$br" --workspace "w-$lane" "$@" >/dev/null
    k lane set --repo "$K_REPO" --lane "$lane" --key status --value "done" >/dev/null
}
kst '{}'
kgh '{}'

echo "== cleanup: only merged, clean, pushed lanes are ready =="
klane merged-1 feat/merged-1 solo --gate t
k lane node --repo "$K_REPO" --lane merged-1 --node impl --status "done" --result pass --tab w-merged-1:t2 >/dev/null
k lane node --repo "$K_REPO" --lane merged-1 --node tests --status "done" --result pass --tab w-merged-1:t3 >/dev/null
head_a="$(git -C "$K_TMP/wt-merged-1" rev-parse HEAD)"
kgh "{\"feat/merged-1\": {\"state\": \"OPEN\", \"number\": 11, \"url\": \"https://github.com/o/r/pull/11\", \"headRefOid\": \"$head_a\"}}"
out="$(k cleanup check --repo "$K_REPO" 2>&1)"
check "a lane whose pull request is open waits" "WAIT merged-1 (pull request https://github.com/o/r/pull/11 is OPEN)" "$out"
check "a lane without a recorded pull request is looked up by branch" "pr view feat/merged-1" "$(cat "$K_TMP/gh.log")"
check "a waiting lane asks nothing" "" "$(klf '.question' merged-1)"
k lane new --repo "$K_REPO" --lane open-1 --pattern investigate --idea x >/dev/null
check_absent "an open lane is not a cleanup candidate" "open-1" "$out"
kgh "{\"feat/merged-1\": {\"state\": \"MERGED\", \"number\": 11, \"url\": \"https://github.com/o/r/pull/11\", \"headRefOid\": \"$head_a\"}}"
out="$(k cleanup check --repo "$K_REPO" 2>&1)"
check "a merged, clean, pushed lane is ready" "CLEANUP merged-1 (pull request https://github.com/o/r/pull/11 is merged" "$out"
check "the lane gets a cleanup question" "Cleanup merged-1:" "$(klf '.question' merged-1)"
check "the question asks for confirmation and keeps the branch" "the branch feat/merged-1 is kept" "$(klf '.question' merged-1)"
check "the lane records the pending cleanup" "ready" "$(klf '.cleanup' merged-1)"
check "the user is notified" "notification show merged-1 needs you" "$(cat "$K_TMP/calls.log")"
check_absent "check never removes a worktree" "worktree remove" "$(cat "$K_TMP/calls.log")"
check_absent "check never closes a tab" "tab close" "$(cat "$K_TMP/calls.log")"
check "the lane is under NEEDS YOU" "NEEDS YOU" "$(k status --text --repo "$K_REPO")"
check "status --text shows the pending cleanup" "cleanup: ready" "$(k status --text --repo "$K_REPO" | grep -A3 'merged-1')"
check "status --json carries it for the panel" "ready" "$(k status --json --repo "$K_REPO" | jq -r '.[] | select(.lane == "merged-1") | .cleanup')"
kst '{}'
out="$(k cleanup check --repo "$K_REPO" 2>&1)"
check "a pending cleanup is not asked twice" "PENDING merged-1" "$out"
check_absent "and not notified twice" "notification" "$(cat "$K_TMP/calls.log")"

echo "== cleanup: a recorded pull request, a dirty checkout, unpushed commits =="
klane dirty-1 feat/dirty-1 solo --gate t
k lane set --repo "$K_REPO" --lane dirty-1 --key pr --value https://github.com/o/r/pull/12 >/dev/null
head_d="$(git -C "$K_TMP/wt-dirty-1" rev-parse HEAD)"
kgh "{\"https://github.com/o/r/pull/12\": {\"state\": \"MERGED\", \"number\": 12, \"url\": \"https://github.com/o/r/pull/12\", \"headRefOid\": \"$head_d\"}}"
echo scratch >"$K_TMP/wt-dirty-1/notes.txt"
kst '{}'
out="$(k cleanup check --repo "$K_REPO" --lane dirty-1 2>&1)"
check "the recorded pull request is used" "pr view https://github.com/o/r/pull/12" "$(cat "$K_TMP/gh.log")"
check "a merged lane with a dirty checkout is not ready" "BLOCKED dirty-1 (the checkout has uncommitted changes" "$out"
check "it goes to the user with the reason" "uncommitted changes" "$(klf '.question' dirty-1)"
check "the user is notified about it" "notification show dirty-1 needs you" "$(cat "$K_TMP/calls.log")"
k lane answer --repo "$K_REPO" --lane dirty-1 --text "I will look" >/dev/null
kst '{}'
out="$(k cleanup check --repo "$K_REPO" --lane dirty-1 2>&1)"
check "the same reason is not asked again" "BLOCKED dirty-1" "$out"
check "after an answer the question stays cleared" "" "$(klf '.question' dirty-1)"
check_absent "nor notified again" "notification" "$(cat "$K_TMP/calls.log")"
rm "$K_TMP/wt-dirty-1/notes.txt"
kc "$K_TMP/wt-dirty-1" "after the merge"
out="$(k cleanup check --repo "$K_REPO" --lane dirty-1 2>&1)"
check "commits after the pull request's head are unpushed" "BLOCKED dirty-1 (1 commit not in the pull request" "$out"
check "a new reason is asked again" "not in the pull request" "$(klf '.question' dirty-1)"
out="$(k cleanup run --repo "$K_REPO" --lane dirty-1 2>&1)"; rc=$?
check_rc "cleanup refuses a lane that is not ready" 6 "$rc"
check "the refusal says why" "not in the pull request" "$out"
check_absent "nothing is removed" "worktree remove" "$(cat "$K_TMP/calls.log")"

echo "== cleanup: a pr node's pull request is used =="
klane fast-1 fix/fast-1 fast --gate t
head_f="$(git -C "$K_TMP/wt-fast-1" rev-parse HEAD)"
k lane node --repo "$K_REPO" --lane fast-1 --node pr --status "done" --result pass --ref https://github.com/o/r/pull/13 >/dev/null
kgh "{\"https://github.com/o/r/pull/13\": {\"state\": \"MERGED\", \"number\": 13, \"url\": \"https://github.com/o/r/pull/13\", \"headRefOid\": \"$head_f\"}}"
kst '{}'
: >"$K_TMP/gh.log"
out="$(k cleanup check --repo "$K_REPO" --lane fast-1 2>&1)"
check "the pull request a pr node opened is looked up" "pr view https://github.com/o/r/pull/13" "$(cat "$K_TMP/gh.log")"
check "a merged fast lane is ready" "CLEANUP fast-1 (pull request https://github.com/o/r/pull/13 is merged" "$out"

echo "== cleanup: review and report lanes need no merge =="
klane rev-7 look/pr-7 review --input pr=https://github.com/o/r/pull/7
kst '{}'
: >"$K_TMP/gh.log"
out="$(k cleanup check --repo "$K_REPO" --lane rev-7 2>&1)"
check "a done review lane is ready without a merge" "CLEANUP rev-7 (review lane is done" "$out"
check_absent "no pull request is looked up for it" "pr view" "$(cat "$K_TMP/gh.log")"
git -C "$K_REPO" worktree add -q -b inv/why "$K_TMP/wt-inv-1" main
k lane new --repo "$K_REPO" --lane inv-1 --pattern investigate --idea x --branch inv/why --workspace w-inv-1 >/dev/null
k lane set --repo "$K_REPO" --lane inv-1 --key status --value "done" >/dev/null
out="$(k cleanup check --repo "$K_REPO" --lane inv-1 2>&1)"
check "a done report lane with nothing unpushed is ready" "CLEANUP inv-1 (report lane is done" "$out"

echo "== cleanup: the user says no =="
k lane answer --repo "$K_REPO" --lane inv-1 --text "no, keep it" >/dev/null
k lane set --repo "$K_REPO" --lane inv-1 --key cleanup --value declined >/dev/null
kst '{}'
out="$(k cleanup check --repo "$K_REPO" --lane inv-1 2>&1)"
check "a declined cleanup is not asked again" "DECLINED inv-1" "$out"
check "the question stays cleared" "" "$(klf '.question' inv-1)"
out="$(k lane set --repo "$K_REPO" --lane inv-1 --key cleanup --value maybe 2>&1)"; rc=$?
check_rc "cleanup takes only known values" 2 "$rc"

echo "== cleanup: the user says yes =="
kgh "{\"feat/merged-1\": {\"state\": \"MERGED\", \"number\": 11, \"url\": \"https://github.com/o/r/pull/11\", \"headRefOid\": \"$head_a\"}}"
kst '{"tabs": {"w-merged-1:t2": {"tab_id": "w-merged-1:t2", "workspace_id": "w-merged-1", "number": 2, "agent_status": "idle"}, "w-merged-1:t3": {"tab_id": "w-merged-1:t3", "workspace_id": "w-merged-1", "number": 2, "agent_status": "idle"}}, "worktree_remove": "fail"}'
out="$(k cleanup run --repo "$K_REPO" --lane merged-1 2>&1)"; rc=$?
check_rc "a failed worktree removal stops the cleanup" 1 "$rc"
check "the lane's agent tabs are closed first" "tab close w-merged-1:t2" "$(cat "$K_TMP/calls.log")"
check "the lane's gate tabs are closed first" "tab close w-merged-1:t3" "$(cat "$K_TMP/calls.log")"
check "the lane stays open after a failed removal" "done" "$(klf '.status' merged-1)"
check_absent "removal is never forced" "--force" "$(cat "$K_TMP/calls.log")"
kst '{"tabs": {"w-merged-1:t2": {"tab_id": "w-merged-1:t2", "workspace_id": "w-merged-1", "number": 2, "agent_status": "idle"}, "w-merged-1:t3": {"tab_id": "w-merged-1:t3", "workspace_id": "w-merged-1", "number": 2, "agent_status": "idle"}}}'
out="$(k cleanup run --repo "$K_REPO" --lane merged-1 2>&1)"; rc=$?
check_rc "cleanup succeeds" 0 "$rc"
calls="$(cat "$K_TMP/calls.log")"
check "the worktree is removed through herdr" "worktree remove --workspace w-merged-1" "$calls"
check_absent "never with --force" "--force" "$calls"
check "the lane is closed" "merged-1	closed" "$(k lane list --all --repo "$K_REPO")"
check "the cleanup is reported" "CLEANED merged-1" "$out"
check "the branch is kept" "feat/merged-1" "$(git -C "$K_REPO" branch --list feat/merged-1)"
check "the confirmation is in the history" "answer: cleanup confirmed" "$(klf '.history | join("\n")' merged-1)"

echo "== cleanup: the skill runs the check and asks first =="
orch="$(cat "$PLUGIN/skills/orchestrate/SKILL.md")"
check "orchestrate: checks for cleanup on every report" 'cleanup.sh" check' "$orch"
check "orchestrate: cleans up only after the user confirms" 'cleanup.sh" run --lane L --repo R' "$orch"
check "orchestrate: a no is recorded" "--key cleanup --value declined" "$orch"

git -C "$K_REPO" worktree prune 2>/dev/null
rm -rf "$K_TMP"
unset XDG_CONFIG_HOME
unset -f k kst kgh klf kc klane
