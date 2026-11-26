#!/usr/bin/env bash
# section-prnode.sh -- sourced by run-tests.sh; do not run standalone.
# The pr node: the orchestrator opens the draft pull request mid-graph (the fast pattern),
# before the gate; a retry to the implementer runs it again so fixes reach the same pull request.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }
echo "== graph: pr node =="

P_TMP="$(mktemp -d)"
P_REPO="$P_TMP/repo"
git init -q -b main "$P_REPO" && git -C "$P_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
pg() { local s="$1"; shift; XDG_CONFIG_HOME="$P_TMP/config" PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$P_TMP" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 bash "$PLUGIN/scripts/$s.sh" "$@"; }
plf() { yq -r "$1" "$(git -C "$P_REPO" rev-parse --path-format=absolute --git-common-dir)/herdr-graph/$2.yaml"; }

PB="$P_TMP/p.yaml"
printf 'when: x\nnodes:\n  a: {agent: implementer, brief: "{idea}"}\n  p: {pr: draft, needs: [a]}\ndone: [draft-pr]\n' >"$PB"
check "a pr node is a node kind" "PATTERN OK" "$(pg check-pattern "$PB" 2>&1)"
printf 'when: x\nnodes:\n  a: {agent: implementer, brief: "{idea}"}\n  p: {pr: ready, needs: [a]}\n  q: {pr: draft, agent: implementer}\n  r: {pr: draft, needs: [a], access: write}\n' >"$PB"
out="$(pg check-pattern "$PB" 2>&1)"; rc=$?
check_rc "a bad pr node is refused" 6 "$rc"
check "a pr node only opens drafts" "node p: pr must be draft" "$out"
check "a pr node is one kind only" "node q: needs exactly one of agent, gate, human, pr" "$out"
check "a pr node takes no access" "node r: access is only for agent nodes" "$out"

pg lane new --repo "$P_REPO" --lane fix-x --pattern fast --idea "fix the crash" --gate "npm test" >/dev/null 2>&1
check "a fast lane starts with the implementer" "READY impl agent fast-implementer" "$(pg ready --repo "$P_REPO" --lane fix-x)"
pg lane node --repo "$P_REPO" --lane fix-x --node impl --status "done" --result pass --ref a1b2c3 >/dev/null
out="$(pg ready --repo "$P_REPO" --lane fix-x)"
check "the draft pull request is next, before the gate" "READY pr pr draft" "$out"
check_absent "the gate waits for the pull request" "READY tests" "$out"
pg lane node --repo "$P_REPO" --lane fix-x --node pr --status "done" --result pass --ref https://example.test/pull/1 >/dev/null
check "the gate runs once the pull request is open" "READY tests gate npm test" "$(pg ready --repo "$P_REPO" --lane fix-x)"
pg lane node --repo "$P_REPO" --lane fix-x --node tests --status failed --result fail --exit 1 >/dev/null
check "a failing gate retries the implementer" "RETRY fix-x impl 1/3" "$(pg lane retry --repo "$P_REPO" --lane fix-x --node tests 2>&1)"
check "the pr node runs again after the fix, so it reaches the open pull request" "waiting waiting waiting" "$(plf '[.nodes.impl.status, .nodes.pr.status, .nodes.tests.status] | join(" ")' fix-x)"
rm -rf "$P_TMP"
