#!/usr/bin/env bash
# section-reviewowner.sh -- sourced by run-tests.sh; do not run standalone.
# review-owner.sh: the open lane (in any repository with lanes) whose branch is a reviewed pull
# request's head branch, and its implementer agent when that agent is live.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }
echo "== review-owner.sh =="

O_TMP="$(mktemp -d)"
OA="$O_TMP/repo-a" OB="$O_TMP/repo-b"
for r in "$OA" "$OB"; do
    git init -q -b main "$r" && git -C "$r" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
done
og() { local s="$1"; shift; (cd "$OA" && env -u HERDR_PANE_ID PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$O_TMP" HERDR_ENV=1 GH_STUB_DIR="$O_TMP" GRAPH_GH="$FIX/stub-gh/gh" XDG_CONFIG_HOME="$O_TMP/config" bash "$PLUGIN/scripts/$s.sh" "$@"); }
ost() { # live agents json
    printf '{"workspaces":[{"workspace_id":"w1","worktree":{"repo_root":"%s"}},{"workspace_id":"w2","worktree":{"repo_root":"%s"}}],"agents":%s}' "$OA" "$OB" "$1" >"$O_TMP/state.json"
}
URL="https://github.com/o/r/pull/595"
printf '{"number":595,"url":"%s","headRefName":"feat/close-finished","state":"OPEN"}' "$URL" >"$O_TMP/pr-595.json"
ost '{}'

out="$(og review-owner 2>&1)"; rc=$?
check_rc "review-owner needs --pr" 2 "$rc"
check "and says how to call it" "usage: review-owner.sh" "$out"

check "no lane on the head branch: NONE" "NONE $URL (head feat/close-finished)" "$(og review-owner --pr "$URL" 2>&1)"

# the review lane itself lives in repository A; the reviewed work in repository B
og lane new --repo "$OA" --lane review-pr-595 --pattern review --idea "review 595" --input pr="$URL" --branch look/pr-595 >/dev/null
og lane new --repo "$OB" --lane close-finished --pattern solo --idea "close agents" --gate "make test" --branch feat/close-finished >/dev/null
og lane node --repo "$OB" --lane close-finished --node impl --status "done" --result pass --agent claude-close-finished-impl >/dev/null

check "an owner whose agent is gone prints - for the agent" "OWNER $OB close-finished - impl" "$(og review-owner --pr "$URL" 2>&1)"

ost '{"a1":{"name":"claude-close-finished-impl","pane_id":"w2:p2","agent_status":"idle"}}'
out="$(og review-owner --pr "$URL" 2>&1)"; rc=$?
check_rc "an owner found exits 0" 0 "$rc"
check "the owner lane in another repository, with its live implementer" "OWNER $OB close-finished claude-close-finished-impl impl" "$out"
check_absent "the review lane is not its own owner" "review-pr-595" "$out"
check "an explicit --repo is read too" "OWNER $OB close-finished" "$(og review-owner --pr "$URL" --repo "$OB" 2>&1)"

og lane close --repo "$OB" --lane close-finished >/dev/null
check "a closed lane owns nothing" "NONE $URL" "$(og review-owner --pr "$URL" 2>&1)"

: >"$O_TMP/gh-fail"
out="$(og review-owner --pr "$URL" 2>&1)"; rc=$?
check_rc "gh failing exits 1" 1 "$rc"
check "and says the owner is unknown" "UNKNOWN $URL" "$out"
rm -rf "$O_TMP"
