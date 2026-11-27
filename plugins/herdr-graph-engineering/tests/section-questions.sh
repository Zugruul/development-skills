#!/usr/bin/env bash
# section-questions.sh -- sourced by run-tests.sh; do not run standalone.
# lane.sh keeps every open question (not one slot), and answering one never re-arms a node whose
# agent is still live: ready.sh must never offer a second writer.
declare -F check >/dev/null 2>&1 || { echo "section files are sourced by run-tests.sh; run: bash plugins/herdr-graph-engineering/tests/run-tests.sh" >&2; exit 2; }

Q_TMP="$(mktemp -d)"
Q_REPO="$Q_TMP/repo"
git init -q -b main "$Q_REPO" && git -C "$Q_REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
qs() { local s="$1"; shift; PATH="$FIX/stub-herdr:$PATH" HERDR_STUB_DIR="$Q_TMP" HERDR_ENV=1 bash "$PLUGIN/scripts/$s.sh" "$@"; }
ql() { qs lane show --repo "$Q_REPO" --lane "$1" --json | jq -r "$2"; }
qst() { printf '%s' "$1" >"$Q_TMP/state.json"; : >"$Q_TMP/calls.log"; }
qlive='{"agents": {"a": {"name": "claude-q-impl", "pane_id": "w1:p2", "agent_status": "blocked"}}}'

echo "== questions: two questions both survive =="
qst "$qlive"
qs lane new --repo "$Q_REPO" --lane q --pattern solo --idea x --gate true >/dev/null
qs lane node --repo "$Q_REPO" --lane q --node impl --status running --agent claude-q-impl >/dev/null
out="$(qs lane ask --repo "$Q_REPO" --lane q --node impl --text "UTC or local time?")"
check "ask prints the question's id" "QUESTION 1" "$out"
out="$(qs lane ask --repo "$Q_REPO" --lane q --text "Which branch?")"
check "a second question gets its own id" "QUESTION 2" "$out"
check "both questions are kept" "2" "$(ql q '[.questions[] | select(.answer == null)] | length')"
check "the lane's question line shows the first" "UTC or local time?" "$(ql q .question)"
check "and the second" "Which branch?" "$(ql q .question)"

echo "== questions: answering one keeps the other =="
out="$(qs lane answer --repo "$Q_REPO" --lane q --text "UTC" 2>&1)"; rc=$?
check_rc "an answer without an id is refused while two are open" 2 "$rc"
check "the refusal lists the open ids" "1, 2" "$out"
qs lane answer --repo "$Q_REPO" --lane q --id 1 --text "UTC" >/dev/null
check_absent "the answered question leaves the question line" "UTC or local" "$(ql q .question)"
check "the other stays" "Which branch?" "$(ql q .question)"
check "the answer is recorded with its question" "UTC" "$(ql q '.questions[0].answer')"

echo "== questions: a live agent's node returns to running =="
check "its node is running again, not waiting" "running" "$(ql q .nodes.impl.status)"
qs lane answer --repo "$Q_REPO" --lane q --text "main" >/dev/null
check "the only open question needs no id" "" "$(ql q .question)"
out="$(qs ready --repo "$Q_REPO" --lane q)"
check_absent "ready.sh offers no second writer" "READY impl" "$out"
check "it says the node is running" "running: impl" "$out"

echo "== questions: a gone agent's node returns to waiting =="
qs lane ask --repo "$Q_REPO" --lane q --node impl --text "again?" >/dev/null
qst '{"agents": {}}'
qs lane answer --repo "$Q_REPO" --lane q --text "yes" >/dev/null
check "a gone agent's node waits to be started" "waiting" "$(ql q .nodes.impl.status)"
check "ready.sh offers it" "READY impl" "$(qs ready --repo "$Q_REPO" --lane q)"

echo "== questions: without a herdr answer a recorded agent counts as live =="
qs lane node --repo "$Q_REPO" --lane q --node impl --status running --agent claude-q-impl >/dev/null
qs lane ask --repo "$Q_REPO" --lane q --node impl --text "one more?" >/dev/null
qst 'not json'
qs lane answer --repo "$Q_REPO" --lane q --text "no" >/dev/null
check "liveness unknown: running, never a second writer" "running" "$(ql q .nodes.impl.status)"

echo "== questions: a node with two questions stays blocked until both are answered =="
qst "$qlive"
qs lane ask --repo "$Q_REPO" --lane q --node impl --text "first?" >/dev/null
qs lane ask --repo "$Q_REPO" --lane q --node impl --text "second?" >/dev/null
qs lane answer --repo "$Q_REPO" --lane q --id "$(ql q '[.questions[] | select(.answer == null)][0].id')" --text a >/dev/null
check "still blocked" "blocked" "$(ql q .nodes.impl.status)"
qs lane answer --repo "$Q_REPO" --lane q --text b >/dev/null
check "running after the last" "running" "$(ql q .nodes.impl.status)"

echo "== questions: a human node waits again, and other blocked nodes are left alone =="
qs lane new --repo "$Q_REPO" --lane h --pattern solo --idea x --gate true >/dev/null
qs lane ask --repo "$Q_REPO" --lane h --node impl --text "go?" >/dev/null
qs lane node --repo "$Q_REPO" --lane h --node tests --status blocked >/dev/null
qs lane answer --repo "$Q_REPO" --lane h --text "go" >/dev/null
check "a node without an agent waits again" "waiting" "$(ql h .nodes.impl.status)"
check "a node the question was not about is untouched" "blocked" "$(ql h .nodes.tests.status)"

echo "== questions: asked marks a question as shown to the user =="
qs lane ask --repo "$Q_REPO" --lane h --text "merge order?" >/dev/null
id="$(ql h '[.questions[] | select(.answer == null)][0].id')"
check "a new question is not asked yet" "null" "$(ql h '[.questions[] | select(.answer == null)][0].asked_at')"
qs lane asked --repo "$Q_REPO" --lane h --id "$id" >/dev/null
check "asked records when" "T" "$(ql h '[.questions[] | select(.answer == null)][0].asked_at')"

echo "== questions: an old lane file with one question string still works =="
f="$(git -C "$Q_REPO" rev-parse --path-format=absolute --git-common-dir)/herdr-graph/h.yaml"
yq -i 'del(.questions) | .question = "old style?"' "$f"
out="$(qs lane ask --repo "$Q_REPO" --lane h --text "new style?")"
check "the old question is kept" "old style?" "$(ql h .question)"
check "beside the new one" "new style?" "$(ql h .question)"
qs lane answer --repo "$Q_REPO" --lane h --id 1 --text ok >/dev/null
check_absent "the old one can be answered" "old style?" "$(ql h .question)"
yq -i 'del(.questions) | .question = "only the old one?" | .nodes.impl.status = "blocked"' "$f"
qs lane answer --repo "$Q_REPO" --lane h --text ok >/dev/null
check "an old lane's answer clears it" "" "$(ql h .question)"
check "and unblocks as before" "waiting" "$(ql h .nodes.impl.status)"

echo "== questions: the retry limit adds a question and keeps others =="
qs lane new --repo "$Q_REPO" --lane r --pattern solo --idea x --gate true >/dev/null
qs lane ask --repo "$Q_REPO" --lane r --text "unrelated?" >/dev/null
for _ in 1 2 3 4; do
    qs lane node --repo "$Q_REPO" --lane r --node tests --status failed >/dev/null
    qs lane retry --repo "$Q_REPO" --lane r --node tests >/dev/null 2>&1 || break
done
check "the retry limit question is added" "Retry limit reached" "$(ql r .question)"
check "the earlier question survives" "unrelated?" "$(ql r .question)"

rm -rf "$Q_TMP"
unset -f qs ql qst
