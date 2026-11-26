#!/usr/bin/env bash
# section-graph.sh -- sourced by run-tests.sh; do not run standalone.
# The graph scripts against throwaway repositories and the stub herdr: patterns, lane files,
# ready nodes, retries and their limit, questions, the lock, kinds, gates and the status picture.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

G_TMP="$(mktemp -d)"
SC="$PLUGIN/scripts"
REPO="$G_TMP/repo"
git init -q -b main "$REPO" && git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
export XDG_CONFIG_HOME="$G_TMP/config"   # no user patterns or roles leak in
g() { local s="$1"; shift; (cd "$G_TMP" && PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$G_TMP" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 bash "$SC/$s.sh" "$@"); }
st() { printf '%s' "$1" >"$G_TMP/state.json"; : >"$G_TMP/calls.log"; }
lf() { yq -r "$1" "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/herdr-graph/$2.yaml"; }
st '{}'

echo "== graph: patterns =="
for p in solo investigate; do
    check "built-in pattern $p is valid" "PATTERN OK" "$(g check-pattern --name "$p" --repo "$REPO" 2>&1)"
done
BAD="$G_TMP/bad.yaml"
printf 'when: x\nnodes:\n  a: {agent: implementer, needs: [b], brief: "{nope}"}\n  b: {gate: "x", needs: [a], retry: {to: a}}\n  c: {human: q, agent: ghost, colour: red}\ndone: [{gate: zz}, merge]\n' >"$BAD"
out="$(g check-pattern "$BAD" 2>&1)"; rc=$?
check_rc "a broken pattern is refused" 6 "$rc"
for p in "retry needs max" "needs exactly one of agent, gate, human" "unknown key colour" "form a cycle" "gate zz is not a node" "unknown check merge" "not declared in inputs: nope" "unknown role: ghost"; do
    check "pattern problem found: $p" "$p" "$out"
done
printf 'when: x\nnodes: [1, 2]\n' >"$BAD"
out="$(g check-pattern "$BAD" 2>&1)"; rc=$?
check_rc "a pattern of the wrong shape is refused, not crashed" 6 "$rc"
mkdir -p "$REPO/.herdr-graph/patterns"
printf 'when: "repo own"\ninputs: [idea]\nnodes:\n  look: {agent: investigator, brief: "{idea}"}\ndone: [report]\n' >"$REPO/.herdr-graph/patterns/investigate.yaml"
check "a repository pattern wins over the plugin's" "(repo)" "$(g check-pattern --name investigate --repo "$REPO" 2>&1)"
rm -rf "$REPO/.herdr-graph"

echo "== graph: lane files =="
out="$(g lane new --repo "$REPO" --lane task-x --pattern solo --idea "add a limiter" 2>&1)"; rc=$?
check_rc "a gate pattern needs an approved gate command" 2 "$rc"
check "the refusal says why" "MISSING GATE" "$out"
out="$(g lane new --repo "$REPO" --lane "Task X" --pattern solo --idea i --gate t 2>&1)"; rc=$?
check_rc "a lane name must be a slug" 2 "$rc"
out="$(g lane new --repo "$REPO" --lane task-x --pattern solo --idea "add a limiter" --gate "npm test" --branch feat/task-x 2>&1)"; rc=$?
check_rc "a lane is created" 0 "$rc"
check "the lane file lives in the git common dir" "/.git/herdr-graph/task-x.yaml" "$out"
check "the graph is copied with the idea filled in" "add a limiter" "$(lf '.graph.impl.brief' task-x)"
check "the gate placeholder is the approved command" "npm test" "$(lf '.graph.tests.gate' task-x)"
check "every node starts waiting" "waiting waiting" "$(lf '[.nodes[].status] | join(" ")' task-x)"
check_absent "the lane file is not in the working tree" "herdr-graph" "$(git -C "$REPO" status --porcelain)"
out="$(g lane new --repo "$REPO" --lane task-x --pattern solo --idea again --gate t 2>&1)"; rc=$?
check_rc "an existing lane is not overwritten" 6 "$rc"
check "list shows the open lane" "task-x	open	solo" "$(g lane list --repo "$REPO")"

echo "== graph: ready and retry =="
check "only the first node is ready" "READY impl agent implementer" "$(g ready --repo "$REPO" --lane task-x)"
check_absent "the gate waits for impl" "READY tests" "$(g ready --repo "$REPO" --lane task-x)"
g lane node --repo "$REPO" --lane task-x --node impl --status "done" --result pass --ref a1b2c3 >/dev/null
check "the gate is ready once impl is done" "READY tests gate npm test" "$(g ready --repo "$REPO" --lane task-x)"
g lane node --repo "$REPO" --lane task-x --node tests --status failed --result fail --exit 1 >/dev/null
check "a failed node blocks the lane until it is retried" "NOTHING READY (failed, not retried: tests)" "$(g ready --repo "$REPO" --lane task-x)"
out="$(g lane retry --repo "$REPO" --lane task-x --node tests 2>&1)"; rc=$?
check_rc "the first retry is allowed" 0 "$rc"
check "retry names the target and the count" "RETRY task-x impl 1/3" "$out"
check "retry resets the target and what follows it" "waiting waiting" "$(lf '[.nodes.impl.status, .nodes.tests.status] | join(" ")' task-x)"
check "retry keeps the reference" "a1b2c3" "$(lf '.nodes.impl.ref' task-x)"
for i in 2 3; do
    g lane node --repo "$REPO" --lane task-x --node impl --status "done" --result pass >/dev/null
    g lane node --repo "$REPO" --lane task-x --node tests --status failed --result fail --exit 1 >/dev/null
    g lane retry --repo "$REPO" --lane task-x --node tests >/dev/null
done
g lane node --repo "$REPO" --lane task-x --node impl --status "done" --result pass >/dev/null
g lane node --repo "$REPO" --lane task-x --node tests --status failed --result fail --exit 1 >/dev/null
out="$(g lane retry --repo "$REPO" --lane task-x --node tests 2>&1)"; rc=$?
check_rc "the retry limit stops the loop" 7 "$rc"
check "the limit is reported" "RETRY LIMIT task-x: impl retried 3/3" "$out"
check "the limit becomes a question for the user" "Retry limit reached" "$(lf '.question' task-x)"
check "with a question open nothing runs" "NOTHING READY (open question" "$(g ready --repo "$REPO" --lane task-x)"
g lane answer --repo "$REPO" --lane task-x --text "try once more" >/dev/null
check "the answer clears the question" "" "$(lf '.question' task-x)"
check "the answer is in the history" "answer: try once more" "$(lf '.history | join("\n")' task-x)"

echo "== graph: lock =="
g lane new --repo "$REPO" --lane busy --pattern investigate --idea "why" >/dev/null
for i in $(seq 1 12); do g lane node --repo "$REPO" --lane busy --node investigate --status running --note "w$i" >/dev/null 2>&1 & done; wait
check_rc "parallel writes lose nothing" 12 "$(lf '[.history[] | select(test(" w[0-9]+$"))] | length' busy)"
d="$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)/herdr-graph"
mkdir "$d/.lock" && echo 999999 >"$d/.lock/pid"
out="$(g lane node --repo "$REPO" --lane busy --node investigate --status "done" --result pass 2>&1)"; rc=$?
check_rc "a stale lock of a dead process is taken over" 0 "$rc"

echo "== graph: kinds =="
BIN="$G_TMP/bin"; mkdir -p "$BIN"
for k in claude opencode; do printf '#!/bin/sh\n' >"$BIN/$k"; chmod +x "$BIN/$k"; done
kind() { PATH="$BIN:/usr/bin:/bin:$(dirname "$(command -v yq)"):$(dirname "$(command -v jq)")" bash "$SC/kind.sh" "$@"; }
out="$(kind --role investigator)"
check "a read-only role picks the first installed kind" "KIND claude" "$out"
check "read-only Claude denies the edit tools" "ARGS --disallowedTools Edit Write NotebookEdit" "$out"
out="$(kind --role investigator --not claude)"
check "a second opinion uses another installed kind" "KIND opencode" "$out"
check "read-only opencode uses its plan agent" "ARGS --agent plan" "$out"
rm "$BIN/opencode"
out="$(kind --role investigator --not claude)"
check "with one kind installed it says the review is same-model" "SAME-KIND" "$out"
out="$(kind --role implementer)"
check "a write role gets no read-only arguments" "ARGS " "$out"
check_absent "a write role gets no deny list" "disallowedTools" "$out"

echo "== graph: gate =="
g lane new --repo "$REPO" --lane gated --pattern solo --idea "x" --gate "npm test" >/dev/null
g lane node --repo "$REPO" --lane gated --node impl --status "done" --result pass >/dev/null
st '{"gate_exit":0}'
out="$(g gate --repo "$REPO" --lane gated --node tests --pane w2:p2 --timeout 2 2>&1)"; rc=$?
check_rc "a passing gate exits 0" 0 "$rc"
check "the gate reports pass" "GATE PASS tests EXIT=0" "$out"
check "the gate result is recorded" "done pass 0" "$(lf '[.nodes.tests.status, .nodes.tests.result, .nodes.tests.exit] | join(" ")' gated)"
check "the command runs in the pane with a marker" 'npm test; echo "GATE tests ' "$(jq -r '.panes["w2:p2"].typed[0]' "$G_TMP/state.json")"
out="$(g lane retry --repo "$REPO" --lane gated --node tests 2>&1)"; rc=$?
check_rc "a node that passed is not retried" 6 "$rc"
g lane node --repo "$REPO" --lane gated --node tests --status waiting >/dev/null
g lane node --repo "$REPO" --lane gated --node impl --status "done" --result pass >/dev/null
st '{"gate_exit":3}'
out="$(g gate --repo "$REPO" --lane gated --node tests --pane w2:p2 --timeout 2 2>&1)"
check "a failing gate reports its exit code" "GATE FAIL tests EXIT=3" "$out"
check "the failure is recorded" "failed 3" "$(lf '[.nodes.tests.status, .nodes.tests.exit] | join(" ")' gated)"
g lane retry --repo "$REPO" --lane gated --node tests >/dev/null 2>&1
g lane node --repo "$REPO" --lane gated --node impl --status "done" --result pass >/dev/null
st '{"gate_hang":true}'
out="$(g gate --repo "$REPO" --lane gated --node tests --pane w2:p2 --timeout 1 2>&1)"; rc=$?
check_rc "a gate that does not finish times out with exit 5" 5 "$rc"
check "the timeout says how to keep waiting" "--resume" "$out"
check "the node stays running" "running" "$(lf '.nodes.tests.status' gated)"

echo "== graph: G2 pair, human, skip, review, custom =="
g lane new --repo "$REPO" --lane pair-x --pattern pair --idea "touch auth" --gate "npm test" >/dev/null
g lane node --repo "$REPO" --lane pair-x --node impl --status "done" --result pass >/dev/null
g lane node --repo "$REPO" --lane pair-x --node tests --status "done" --result pass --exit 0 >/dev/null
check "the second opinion runs after the gate passed" "READY review agent reviewer" "$(g ready --repo "$REPO" --lane pair-x)"
g lane node --repo "$REPO" --lane pair-x --node review --status "done" --result changes --ref /tmp/f.md >/dev/null
check "a review asking for changes blocks like a failure" "NOTHING READY (failed, not retried: review)" "$(g ready --repo "$REPO" --lane pair-x)"
check "it shows as not passed in the picture" "review ✗" "$(g status --text --repo "$REPO" | grep -A0 'pair-x')"
out="$(g lane retry --repo "$REPO" --lane pair-x --node review 2>&1)"
check "changes send the work back to the implementer" "RETRY pair-x impl 1/2" "$out"
check "impl, tests and review all run again" "waiting waiting waiting" "$(lf '[.nodes.impl.status, .nodes.tests.status, .nodes.review.status] | join(" ")' pair-x)"
out="$(g lane new --repo "$REPO" --lane rev-1 --pattern review --idea "look at it" 2>&1)"; rc=$?
check_rc "a review needs the pull request as input" 2 "$rc"
check "the refusal names the missing input" "MISSING INPUT: pr" "$out"
g lane new --repo "$REPO" --lane rev-1 --pattern review --idea "look at it" --input pr=https://github.com/o/r/pull/7 >/dev/null
check "the pull request is filled into the brief" "Review pull request https://github.com/o/r/pull/7" "$(lf '.graph.review.brief' rev-1)"
g lane node --repo "$REPO" --lane rev-1 --node review --status "done" --result pass --ref /tmp/d.md >/dev/null
check "the human approval comes next" "READY approve human Post the review of https://github.com/o/r/pull/7" "$(g ready --repo "$REPO" --lane rev-1)"
g lane node --repo "$REPO" --lane rev-1 --node approve --status "done" --result fail >/dev/null
check "a no skips the posting" "SKIP post (when pass does not hold)" "$(g ready --repo "$REPO" --lane rev-1)"
g lane node --repo "$REPO" --lane rev-1 --node post --status skipped >/dev/null
check "a skipped node counts as finished" "ALL NODES DONE" "$(g ready --repo "$REPO" --lane rev-1)"
check "a skipped node shows a dash" "post –" "$(g status --text --repo "$REPO" | grep 'rev-1')"
STACK="$G_TMP/stack.yaml"
check "a review stack becomes a pattern file" "PATTERN FILE" "$(g make-review-stack --pr https://github.com/o/r/pull/1 --pr https://github.com/o/r/pull/2 --out "$STACK")"
check "the stack pattern is valid" "PATTERN OK" "$(g check-pattern "$STACK" --repo "$REPO")"
out="$(g make-review-stack --pr https://github.com/o/r/pull/1 2>&1)"; rc=$?
check_rc "one pull request is not a stack" 2 "$rc"
g lane new --repo "$REPO" --lane stack-1 --pattern-file "$STACK" --idea "together" >/dev/null
check "a lane starts from a pattern file" "custom" "$(lf '.pattern_from' stack-1)"
check "every reviewer is ready at once" "READY review-1 agent pr-reviewer
READY review-2 agent pr-reviewer" "$(g ready --repo "$REPO" --lane stack-1)"
g lane node --repo "$REPO" --lane stack-1 --node review-1 --status "done" --result pass >/dev/null
check_absent "the cross check waits for every reviewer" "READY cross" "$(g ready --repo "$REPO" --lane stack-1)"
g lane node --repo "$REPO" --lane stack-1 --node review-2 --status "done" --result pass >/dev/null
check "the cross check runs when all reviewers are done" "READY cross agent pr-reviewer" "$(g ready --repo "$REPO" --lane stack-1)"

echo "== graph: status =="
g lane ask --repo "$REPO" --lane busy --node investigate --text "Staging or production?" >/dev/null
st '{}'
out="$(g status --text --repo "$REPO")"
check "a lane with a question needs the user" "NEEDS YOU" "$out"
check "the question is shown" "? Staging or production?" "$out"
check "a running lane is working" "WORKING" "$out"
check "the node chain with retries" "impl ✓ retry 1/3 → tests ⟳" "$(g status --text --repo "$REPO" | grep 'gated')"
check "the tab bar line counts and names the first lane that needs you" "🔴 1 busy" "$(g status --line --repo "$REPO")"
st "{\"agents\":{\"a\":{\"name\":\"claude-gated-impl\",\"agent_status\":\"blocked\"}}}"
g lane node --repo "$REPO" --lane gated --node impl --status running --agent claude-gated-impl >/dev/null
check "a blocked agent puts its lane under NEEDS YOU" "gated" "$(g status --json --repo "$REPO" | jq -r '.[] | select(.section == "needs") | .lane')"
g lane close --repo "$REPO" --lane busy >/dev/null
check_absent "a closed lane leaves the picture" "busy" "$(g status --text --repo "$REPO")"
check "a closed lane is kept in closed/" "busy	closed" "$(g lane list --all --repo "$REPO")"
echo "== graph: measure =="
out="$(g measure --repo "$REPO" --json)"
check "measure lists closed lanes too" "busy" "$(jq -r '.[].lane' <<<"$out")"
check "measure counts the questions asked" "1" "$(jq -r '.[] | select(.lane == "busy") | .questions' <<<"$out")"
check "measure counts retries" "1" "$(jq -r '.[] | select(.lane == "gated") | .retries' <<<"$out")"
check "measure prints totals per pattern" "PATTERN" "$(g measure --repo "$REPO")"
rm -rf "$G_TMP"
unset XDG_CONFIG_HOME
