#!/usr/bin/env bash
# section-afk.sh -- sourced by run-tests.sh; do not run standalone.
# AFK and auto-merge: off until a command sets them, decisions by tier with their evidence, the
# "decided while you were away" list, a merge only when auto-merge is on for the lane and its gate
# and reviews passed on the pull request's head, and the nine checks of an AFK worktree removal.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

A_TMP="$(mktemp -d)"
A_REPO="$A_TMP/repo"
git init -q -b main "$A_REPO" && git -C "$A_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
printf '.env\nbuild/\n' >>"$A_REPO/.git/info/exclude"
A_STATE_OLD="$XDG_STATE_HOME"; export XDG_STATE_HOME="$A_TMP/state" XDG_CONFIG_HOME="$A_TMP/config"
a() { local s="$1"; shift; (cd "$A_REPO" && PATH="$FIX/stub-herdr:$FIX/stub-gh:$PATH" HERDR_STUB_DIR="$A_TMP" GH_STUB_DIR="$A_TMP" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 NO_COLOR=1 bash "$PLUGIN/scripts/$s.sh" "$@"); }
asj() { a session show --json | jq -r "$1"; }
al() { yq -r "$2" "$A_REPO/.git/herdr-graph/$1.yaml"; }
agh() { printf '%s' "$1" >"$A_TMP/gh.json"; : >"$A_TMP/gh.log"; }
ast() { printf '%s' "$1" >"$A_TMP/state.json"; : >"$A_TMP/calls.log"; }
ast '{}'; agh '{}'
a session set --key pane --value w1:p1 >/dev/null

echo "== afk: off until a command turns it on =="
check "a new session is off" "AFK off" "$(a session afk status)"
out="$(a decide add --tier 1 --class retry --lane x --what "retry" --why "gate failed" --reversible no --undo none 2>&1)"; rc=$?
check_rc "nothing is decided while off" 6 "$rc"
check "and says so" "AFK is off" "$out"
out="$(a session afk on)"
check "on: tiers 1 and 2 by default" "AFK on, tiers 1,2" "$out"
check "for all lanes, queued ideas included" "lanes all, queued ideas yes" "$out"
check "without worktree removal" "worktree removal no" "$out"
check "it says its own permission prompts still stop it" "permission prompt" "$out"
check "the state is kept in the session" "on" "$(asj .afk.state)"
check "resume.sh prints it" "AFK on" "$(a resume)"
a session afk off >/dev/null
check "off again" "AFK off" "$(a session afk status)"
out="$(a session afk on --tiers 1 --cleanup --lanes alpha,beta --no-queued)"
check "a narrower scope" "AFK on, tiers 1, lanes alpha,beta, queued ideas no, worktree removal yes" "$out"
a session afk off >/dev/null
out="$(a session afk on --tiers 3 2>&1)"; rc=$?
check_rc "there is no tier 3 scope" 2 "$rc"
a session afk on --until 2000-01-01T00:00:00Z >/dev/null
check "a passed time limit means off" "AFK off" "$(a session afk status)"
a session afk off >/dev/null

echo "== afk: tiers =="
a session afk on >/dev/null
dec() { a decide add --lane x --what "w" --why "because" --reversible no --undo none "$@" 2>&1; }
check "tier 1 is recorded" "DECIDED 1" "$(dec --tier 1 --class retry)"
for c in merge approve force-push mark-ready post-comment delete cleanup-remove clear secrets install spend adopt widen-scope something-else; do
    out="$(dec --tier 1 --class "$c")"; rc=$?
    check_rc "tier 3 is refused: $c" 6 "$rc"
done
check "the refusal says it waits for the user" "TIER 3" "$out"
out="$(dec --tier 1 --class answer)"; rc=$?
check_rc "an answer needs the user's words it follows from" 6 "$rc"
check "with a source it is recorded" "DECIDED" "$(dec --tier 1 --class answer --source 'the idea says "use UTC"')"
out="$(dec --tier 2 --class choice)"; rc=$?
check_rc "tier 2 needs a second opinion file" 6 "$rc"
echo "agree: option b" >"$A_TMP/opinion.md"
check "with one it is recorded" "DECIDED" "$(dec --tier 2 --class choice --second-opinion "$A_TMP/opinion.md")"
out="$(dec --tier 1 --class choice)"; rc=$?
check_rc "a tier 2 class is never tier 1" 6 "$rc"
out="$(a decide add --tier 1 --class retry --lane x --what "set token=abcdef123" --why y --reversible no --undo none 2>&1)"; rc=$?
check_rc "a secret is never stored" 2 "$rc"
a session afk off >/dev/null; a session afk on --tiers 1 --lanes x --no-queued >/dev/null
out="$(dec --tier 2 --class choice --second-opinion "$A_TMP/opinion.md")"; rc=$?
check_rc "tier 2 outside the scope is refused" 6 "$rc"
out="$(a decide add --tier 1 --class retry --lane other --what w --why y --reversible no --undo none 2>&1)"; rc=$?
check_rc "a lane outside the scope is refused" 6 "$rc"
out="$(dec --tier 1 --class start-queued)"; rc=$?
check_rc "queued ideas outside the scope are refused" 6 "$rc"

echo "== afk: decided while you were away =="
out="$(a decide digest)"
check "the digest is a table" "| # | Lane/node | Decision | Why, source | Tier | Undo |" "$out"
check "with what was decided" "because" "$out"
check "and says when something cannot be undone" "**no**" "$out"
a decide seen >/dev/null
check "seen decisions leave the list" "Nothing was decided" "$(a decide digest)"
a session afk off >/dev/null

echo "== auto-merge: off by default, set per session, repository or lane =="
check "off by default" "AUTOMERGE off" "$(a session automerge status --repo "$A_REPO" --lane m)"
a session automerge on >/dev/null
check "on for the session" "AUTOMERGE on (session)" "$(a session automerge status --repo "$A_REPO" --lane m)"
a session automerge off --repo "$A_REPO" >/dev/null
check "a repository off wins over the session" "AUTOMERGE off (repository)" "$(a session automerge status --repo "$A_REPO" --lane m)"
a session automerge on --repo "$A_REPO" --lane m >/dev/null
check "a lane wins over its repository" "AUTOMERGE on (lane)" "$(a session automerge status --repo "$A_REPO" --lane m)"
a session automerge off >/dev/null
check "plain off turns every one off" "AUTOMERGE off" "$(a session automerge status --repo "$A_REPO" --lane m)"

echo "== auto-merge: only a lane whose gate and reviews passed on the PR head =="
alane() { # lane
    git -C "$A_REPO" worktree add -q -b "feat/$1" "$A_TMP/wt-$1" main
    git -C "$A_TMP/wt-$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m work
    a lane new --repo "$A_REPO" --lane "$1" --pattern pair --idea x --gate true --branch "feat/$1" --workspace "w-$1" --owner graph >/dev/null
}
anodes() { local n; for n in $(al "$1" '.graph | keys | .[]'); do a lane node --repo "$A_REPO" --lane "$1" --node "$n" --status "done" --result pass >/dev/null; done; }
apr() { # lane number state [extra jq]
    local head; head="$(git -C "$A_TMP/wt-$1" rev-parse HEAD)"
    jq -cn --arg b "feat/$1" --arg u "https://github.com/o/r/pull/$2" --arg s "$3" --arg h "$head" --argjson n "$2" '{($u): {number: $n, url: $u, state: $s, headRefName: $b, headRefOid: $h, isDraft: true, reviewDecision: "", mergeable: "MERGEABLE", createdAt: "2999-01-01T00:00:00Z", statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS"}]}}' | jq -c ".[] |= (${4:-.})"; }
alane m
a lane set --repo "$A_REPO" --lane m --key pr --value https://github.com/o/r/pull/1 >/dev/null
agh "$(apr m 1 OPEN)"
out="$(a merge run --lane m --repo "$A_REPO" 2>&1)"; rc=$?
check_rc "off: a merge waits for the user" 6 "$rc"
check "and says auto-merge is off" "auto-merge is off" "$out"
check_absent "nothing is merged" "pr merge" "$(cat "$A_TMP/gh.log")"
a session automerge on --repo "$A_REPO" --lane m >/dev/null
check "unfinished nodes block it" "NOT MERGEABLE: m: nodes not passed" "$(a merge check --lane m --repo "$A_REPO" 2>&1)"
anodes m
check "a done node records the head it was done on" "$(git -C "$A_TMP/wt-m" rev-parse HEAD)" "$(al m '.nodes | to_entries | .[0].value.head')"
check "ready once everything passed" "MERGE READY m https://github.com/o/r/pull/1" "$(a merge check --lane m --repo "$A_REPO" 2>&1)"
refused() { # name, expected, extra jq
    agh "$(apr m 1 OPEN "$3")"; out="$(a merge run --lane m --repo "$A_REPO" 2>&1)"; check "$1" "$2" "$out"; check_absent "$1: nothing merged" "pr merge" "$(cat "$A_TMP/gh.log")"; }
refused "a failing CI check blocks it" "checks" '.statusCheckRollup[0].conclusion = "FAILURE"'
refused "a running CI check blocks it" "checks" '.statusCheckRollup[0] = {status: "IN_PROGRESS", conclusion: ""}'
refused "requested changes block it" "review" '.reviewDecision = "CHANGES_REQUESTED"'
refused "a conflict blocks it" "conflict" '.mergeable = "CONFLICTING"'
refused "a closed PR is not merged" "CLOSED" '.state = "CLOSED"'
refused "another branch's PR is not merged" "branch" '.headRefName = "feat/else"'
git -C "$A_TMP/wt-m" -c user.name=t -c user.email=t@t commit -q --allow-empty -m later
agh "$(apr m 1 OPEN)"
check "commits after the gate passed block it" "passed on an older commit" "$(a merge run --lane m --repo "$A_REPO" 2>&1)"
anodes m
a lane ask --repo "$A_REPO" --lane m --text "still open?" >/dev/null
agh "$(apr m 1 OPEN)"
check "an open question blocks it" "open question" "$(a merge run --lane m --repo "$A_REPO" 2>&1)"
a lane answer --repo "$A_REPO" --lane m --text no >/dev/null
echo x >"$A_TMP/wt-m/dirty"
check "a dirty checkout blocks it" "uncommitted" "$(a merge run --lane m --repo "$A_REPO" 2>&1)"
rm "$A_TMP/wt-m/dirty"
agh "$(apr m 1 OPEN)"
out="$(a merge run --lane m --repo "$A_REPO" 2>&1)"; rc=$?
check_rc "everything passed: it merges" 0 "$rc"
log="$(cat "$A_TMP/gh.log")"
check "a draft is marked ready first" "pr ready https://github.com/o/r/pull/1" "$log"
check "merged only at the checked head" "pr merge https://github.com/o/r/pull/1 --squash --match-head-commit $(git -C "$A_TMP/wt-m" rev-parse HEAD)" "$log"
check_absent "never forced past protection" "--admin" "$log"
check_absent "the branch is kept" "--delete-branch" "$log"
check_absent "never approves" "pr review" "$log"
check "the merge is reported" "MERGED m https://github.com/o/r/pull/1" "$out"
check "and recorded like an AFK decision" "merge" "$(asj '[.decisions[] | .class] | last')"
check "listed for the user" "pull/1" "$(a decide digest)"

echo "== afk cleanup: the nine checks =="
a decide seen >/dev/null
alane c
a lane set --repo "$A_REPO" --lane c --key pr --value https://github.com/o/r/pull/2 >/dev/null
anodes c
a lane set --repo "$A_REPO" --lane c --key status --value "done" >/dev/null
cgh() { agh "$(apr c 2 MERGED "${1:-.}")"; }
cagents() { ast "{\"agents\": {\"z\": {\"name\": \"$1\", \"agent_status\": \"$2\", \"cwd\": \"$A_TMP/wt-c\", \"pane_id\": \"w-c:p1\"}}}"; }
cgh; ast '{}'
refuse_afk() { # name expected
    : >"$A_TMP/calls.log"; out="$(a cleanup run --afk --lane c --repo "$A_REPO" 2>&1)"; rc=$?
    check_rc "$1: waits" 6 "$rc"; check "$1" "$2" "$out"; check_absent "$1: nothing removed" "worktree remove" "$(cat "$A_TMP/calls.log")"; }
refuse_afk "1 AFK off" "AFK is off"
a session afk on >/dev/null
refuse_afk "1 AFK without the removal scope" "worktree removal is not in the AFK scope"
a session afk off >/dev/null; a session afk on --cleanup >/dev/null
a lane done-extra --repo "$A_REPO" --lane c --text "plugin reinstalled" >/dev/null
refuse_afk "2 an extra done criterion is unmet" "not done"
a lane done-extra --repo "$A_REPO" --lane c --met 1 >/dev/null
a lane set --repo "$A_REPO" --lane c --key pr --value "" >/dev/null 2>&1 || yq -i '.pr = ""' "$A_REPO/.git/herdr-graph/c.yaml"
refuse_afk "3 no recorded pull request" "no pull request is recorded"
a lane set --repo "$A_REPO" --lane c --key pr --value https://github.com/o/r/pull/2 >/dev/null
cgh '.state = "OPEN"'; refuse_afk "3 gh does not say merged" "OPEN"
cgh '.headRefName = "feat/else"'; refuse_afk "3 the PR is another branch's" "branch"
cgh; echo x >"$A_TMP/wt-c/untracked"; refuse_afk "4 an untracked file" "uncommitted"
rm "$A_TMP/wt-c/untracked"
echo S >"$A_TMP/wt-c/.env"; refuse_afk "5 an ignored file that matters" ".env"
rm "$A_TMP/wt-c/.env"; mkdir -p "$A_TMP/wt-c/build"; echo x >"$A_TMP/wt-c/build/o"
cagents someone-else idle; refuse_afk "6 another agent uses the folder" "someone-else"
al c '.nodes | keys' >/dev/null
a lane node --repo "$A_REPO" --lane c --node "$(al c '.graph | keys | .[0]')" --status "done" --result pass --agent claude-c >/dev/null
cagents claude-c working; refuse_afk "6 a working agent" "working"
ast '{}'
a lane ask --repo "$A_REPO" --lane c --text "one thing" >/dev/null
refuse_afk "7 another open question" "open question"
a lane answer --repo "$A_REPO" --lane c --text ok >/dev/null
a lane set --repo "$A_REPO" --lane c --key cleanup --value declined >/dev/null
refuse_afk "never a kept lane" "kept"
a lane set --repo "$A_REPO" --lane c --key cleanup --value "" >/dev/null
a lane dismiss --repo "$A_REPO" --lane c --reason pr-merged --ref https://github.com/o/r/pull/9 --text w >/dev/null
refuse_afk "never a lane with a dismissed entry" "dismissed"
a lane dismiss --repo "$A_REPO" --lane c --ref https://github.com/o/r/pull/9 --undo >/dev/null
yq -i '.adopted = true' "$A_REPO/.git/herdr-graph/c.yaml"
refuse_afk "8 an adopted lane" "adopted"
yq -i 'del(.adopted)' "$A_REPO/.git/herdr-graph/c.yaml"
cgh; a cleanup check --repo "$A_REPO" --lane c >/dev/null
: >"$A_TMP/calls.log"
out="$(a cleanup run --afk --lane c --repo "$A_REPO" 2>&1)"; rc=$?
check_rc "all nine hold: removed" 0 "$rc"
check "9 through herdr" "worktree remove --workspace w-c" "$(cat "$A_TMP/calls.log")"
check_absent "9 never forced" "--force" "$(cat "$A_TMP/calls.log")"
closed="$(cat "$A_REPO/.git/herdr-graph/closed/c.yaml")"
check "recorded as AFK approval, not as the user's yes" "afk-approved" "$closed"
check_absent "never as confirmed" "cleanup = confirmed" "$closed"
check "the question it asked is withdrawn" "withdrawn: true" "$closed"
check "listed as partly reversible" "partly" "$(a decide digest)"
check "with how to undo it" "lane.sh restore" "$(a decide digest)"
a session afk off >/dev/null

git -C "$A_REPO" worktree prune 2>/dev/null
rm -rf "$A_TMP"
export XDG_STATE_HOME="$A_STATE_OLD"; unset XDG_CONFIG_HOME
unset -f a asj al agh ast dec alane anodes apr refused cgh cagents refuse_afk
